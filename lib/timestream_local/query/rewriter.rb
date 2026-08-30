# frozen_string_literal: true

module TimestreamLocal
  module Query
    # Translates a Timestream (Trino-flavoured) query into something SQLite can
    # run against the per-table views.
    #
    # String literals and comments are held out of the rewrite, so SQL-shaped
    # text inside a string is never touched. Double-quoted identifiers are *not*
    # held out -- they are part of the code, and rewriting them is most of what
    # this class does.
    #
    # Identifiers come out backtick-quoted rather than double-quoted, which is
    # not cosmetic. SQLite's legacy double-quoted-string misfeature means a
    # double-quoted identifier that fails to resolve silently degrades into a
    # string literal: `"events"."host"` becomes the string 'events.host' and
    # every comparison against it is quietly false. Backtick quoting has no such
    # fallback, so an unresolvable identifier is an error instead of a wrong
    # answer. (The fallback cannot be switched off from Ruby -- it needs
    # sqlite3_db_config, which the sqlite3 gem does not expose.)
    class Rewriter
      Result = Struct.new(:sql, :tables, keyword_init: true)

      INTERVAL_UNITS = {
        "ns" => 1, "us" => 1_000, "ms" => 1_000_000,
        "s" => 1_000_000_000, "m" => 60_000_000_000,
        "h" => 3_600_000_000_000, "d" => 86_400_000_000_000
      }.freeze

      IDENT = /"(?:[^"]|"")*"/
      NAME = /[A-Za-z_][\w\-]*/
      PART = /(?:#{IDENT}|#{NAME})/

      MEASURE_VALUE_RE = /\bmeasure_value::(double|bigint|varchar|boolean|timestamp)\b/i
      INTERVAL_RE = /\b(\d+)(ns|us|ms|s|m|h|d)\b(?=\s*[,)])/i

      # SQLite has no varbinary: its affinity rules fall through to NUMERIC, so
      # `CAST('a' AS varbinary)` quietly evaluates to the integer 0 and anything
      # hashing it returns a plausible, wrong answer. BLOB is the real equivalent.
      # Matched only in cast position so a column of that name is left alone.
      VARBINARY_RE = /\bas(\s+)varbinary\b/i

      # SQLite's affinity rules have no case for TIMESTAMP, BOOLEAN or DATE
      # either, so those casts fall through to NUMERIC exactly as varbinary does:
      # `CAST('2026-03-22 17:06:00' AS TIMESTAMP)` evaluates to the integer 2026,
      # and `CAST('true' AS BOOLEAN)` to 0. Both are routed to functions instead.
      # DATE has no unambiguous representation here, so it is rejected rather
      # than guessed at.
      LITERAL_MASK = "__timestream_local_literal_"
      IDENT_MASK = "__timestream_local_ident_"
      MASK_RE = /(\d+)__/
      CAST_BODY = /((?:[^()]|\([^()]*\))*?)/
      CAST_TIMESTAMP_RE = /\bcast\s*\(#{CAST_BODY}\s+as\s+timestamp\s*\)/i
      CAST_BOOLEAN_RE = /\bcast\s*\(#{CAST_BODY}\s+as\s+boolean\s*\)/i
      CAST_DATE_RE = /\bcast\s*\(#{CAST_BODY}\s+as\s+date\s*\)/i

      # `time + 1m`. SQLite would coerce the timestamp string to a number and
      # return arithmetic nonsense without erroring, so the whole expression is
      # rerouted through date_add_ns(). The left operand is deliberately limited
      # to the shapes that actually occur -- a bind parameter, a column, or a
      # no-argument function call -- rather than pretending to parse Trino
      # expressions with a regex; anything else is rejected below.
      INTERVAL_TERM = /(?:@#{NAME}|#{NAME}(?:\s*\(\s*\))?)/
      INTERVAL_ARITH_RE = /(#{INTERVAL_TERM})\s*([+-])\s*(\d+)(ns|us|ms|s|m|h|d)\b/i

      # Any interval literal still standing once both rules have run is in a
      # position we do not handle. Raising beats emitting SQL that runs and
      # returns the wrong rows.
      LEFTOVER_INTERVAL_RE = /\b\d+(?:ns|us|ms|s|m|h|d)\b/i

      # `db.table.column` -- SQLite has no three-part names, and the table is
      # aliased to its bare name below, so the database qualifier is dropped.
      # That is also Trino's scoping rule: the relation's name in scope is the
      # table, not the database-qualified pair.
      QUALIFIED_COLUMN_RE = /(#{PART})\s*\.\s*(#{PART})\s*\.\s*(#{PART})/
      TABLE_REF_RE = /\b(from|join)(\s+)(#{PART})\s*\.\s*(#{PART})/i
      COLLAPSED_TABLE_REF_RE = /\b(from|join)(\s+)(#{IDENT})/i

      # What may legally follow a table reference. Anything else is the query's
      # own alias, and a second one must not be bolted on after it.
      ALIASABLE_FOLLOWERS = %w[
        on where group order having limit offset join left right inner outer
        full cross natural union except intersect window using
      ].freeze

      def initialize(sql)
        @sql = sql.to_s.strip.sub(/;\s*\z/, "")
        @tables = []
      end

      def call
        rewritten = map_segments(rewrite_casts(@sql)) { |kind, text| kind == :code ? rewrite_code(text) : text }
        Result.new(sql: rewritten, tables: @tables.uniq)
      end

      private

      def rewrite_code(code)
        code = code.gsub(QUALIFIED_COLUMN_RE) do
          _database, table, column = Regexp.last_match.captures
          %(#{requote(table)}.#{requote(column)})
        end
        code = code.gsub(TABLE_REF_RE) { qualified_table_reference(Regexp.last_match) }
        code = code.gsub(COLLAPSED_TABLE_REF_RE) { collapsed_table_reference(Regexp.last_match) }
        code = code.gsub(MEASURE_VALUE_RE) { %("measure_value::#{Regexp.last_match(1).downcase}") }

        # Every reference has now been resolved, so from here an identifier is a
        # terminal: nothing inside a quoted name is an operator or a literal.
        # Masking them is what keeps a table called `readings-PT1M-0f9c2a-41830d`
        # from having its `-41830d` read as "minus 41830 days". A masked
        # identifier is still a single term, so `"time" - 5m` keeps working.
        identifiers = []
        code = code.gsub(IDENT) do |identifier|
          identifiers << unquote(identifier)
          "#{IDENT_MASK}#{identifiers.size - 1}__"
        end

        code = code.gsub(VARBINARY_RE) { %(AS#{Regexp.last_match(1)}BLOB) }
        code = code.gsub(INTERVAL_ARITH_RE) do
          term, operator, amount, unit = Regexp.last_match.captures
          nanos = Integer(amount) * INTERVAL_UNITS.fetch(unit.downcase)
          %(date_add_ns(#{term}, #{operator == '-' ? -nanos : nanos}))
        end
        code = code.gsub(INTERVAL_RE) do
          (Integer(Regexp.last_match(1)) * INTERVAL_UNITS.fetch(Regexp.last_match(2).downcase)).to_s
        end
        reject_unhandled_intervals!(code)

        code.gsub(/#{IDENT_MASK}#{MASK_RE}/) { quote(identifiers[Integer(Regexp.last_match(1))]) }
      end

      # A cast body routinely contains a string literal -- `CAST('true' AS BOOLEAN)`
      # -- which would split the expression across segments and leave the pattern
      # unmatched. Literals are therefore masked for the duration of this pass
      # rather than the pattern being loosened.
      def rewrite_casts(sql)
        literals = []
        masked = map_segments(sql) do |kind, text|
          next text if kind == :code

          literals << text
          "#{LITERAL_MASK}#{literals.size - 1}__"
        end

        identifiers = []
        masked = masked.gsub(IDENT) do |identifier|
          identifiers << identifier
          "#{IDENT_MASK}#{identifiers.size - 1}__"
        end

        if CAST_DATE_RE.match?(masked)
          raise ValidationException,
                "CAST(... AS DATE) is not supported by timestream-local; cast to TIMESTAMP instead."
        end

        masked = masked.gsub(CAST_TIMESTAMP_RE) { %(to_timestamp(#{Regexp.last_match(1)})) }
        masked = masked.gsub(CAST_BOOLEAN_RE) { %(to_boolean(#{Regexp.last_match(1)})) }
        masked = masked.gsub(/#{IDENT_MASK}#{MASK_RE}/) { identifiers[Integer(Regexp.last_match(1))] }
        masked.gsub(/#{LITERAL_MASK}#{MASK_RE}/) { literals[Integer(Regexp.last_match(1))] }
      end

      # `FROM db.table` -> `FROM "db.table" AS "table"`. The alias is what makes
      # the bare name addressable, which is how Trino scopes it and how the
      # generated SQL of ORM adapters refers to columns in a join condition.
      def qualified_table_reference(match)
        keyword, space, database, table = match.captures
        reference(keyword, space, unquote(database), unquote(table), match.post_match)
      end

      # The same reference written already-collapsed, as `FROM "db.table"`.
      def collapsed_table_reference(match)
        keyword, space, identifier = match.captures
        name = unquote(identifier)
        return match.to_s unless name.include?(".")

        database, table = name.split(".", 2)
        reference(keyword, space, database, table, match.post_match)
      end

      def reference(keyword, space, database, table, rest)
        @tables << [database, table]
        qualified = %(#{keyword}#{space}"#{database}.#{table}")
        needs_alias?(rest) ? %(#{qualified} AS "#{table}") : qualified
      end

      def needs_alias?(rest)
        stripped = rest.lstrip
        return true if stripped.empty? || stripped.start_with?(",", ")", ";")

        stripped.match?(/\A(?:#{ALIASABLE_FOLLOWERS.join('|')})\b/i)
      end

      def reject_unhandled_intervals!(code)
        leftover = code[LEFTOVER_INTERVAL_RE]
        return unless leftover

        raise ValidationException,
              "Unsupported interval expression near #{leftover.inspect}. Interval literals are supported as " \
              "function arguments (bin(time, 1h)) and added to a column, parameter or no-argument function " \
              "call (time + 1h)."
      end

      # Identifiers stay double-quoted until masking and become backticked only on
      # restore. A rewrite that emitted backticks directly would hand the rest of
      # the pass an identifier the mask cannot see, which is how a three-part
      # reference had its table name read as interval arithmetic.
      def requote(token)
        name = unquote(token)
        %("#{name.gsub('"', '""')}")
      end

      def quote(name)
        "`#{name.gsub('`', '``')}`"
      end

      def unquote(token)
        token.start_with?('"') ? token[1..-2].gsub('""', '"') : token
      end

      # Splits the statement into code, string literals and comments. Only code
      # is rewritten. Double-quoted identifiers stay in the code stream, so a
      # qualified reference is never split across segments.
      def map_segments(sql)
        out = +""
        pos = 0
        while pos < sql.length
          boundary = sql.index(/'|--/, pos)
          if boundary.nil?
            out << yield(:code, sql[pos..])
            break
          end

          out << yield(:code, sql[pos...boundary]) if boundary > pos
          if sql[boundary, 2] == "--"
            stop = sql.index("\n", boundary) || sql.length
            out << yield(:comment, sql[boundary...stop])
            pos = stop
          else
            stop = string_literal_end(sql, boundary)
            out << yield(:string, sql[boundary..stop])
            pos = stop + 1
          end
        end
        out
      end

      # A doubled quote inside a string literal escapes it rather than ending it.
      def string_literal_end(sql, start)
        pos = start + 1
        while (closing = sql.index("'", pos))
          return closing unless sql[closing + 1] == "'"

          pos = closing + 2
        end
        sql.length - 1
      end
    end
  end
end
