# frozen_string_literal: true

module TimestreamLocal
  module Query
    # Static result-column types for a Timestream (Trino) query, read from the
    # SQL rather than from the values SQLite returns.
    #
    # SQLite has one integer type, so a value cannot say whether Trino would
    # call it INTEGER or BIGINT: `SELECT 0` and `SELECT COUNT(*)` both come back
    # as a Ruby Integer. Trino types the first INTEGER and the second BIGINT, and
    # a consumer that only handles BIGINT reads the first as nil -- which is only
    # caught if the emulator reports what Trino reports.
    #
    # Advisory only: anything this does not understand comes out as nil, and
    # the caller falls back to inferring from values. `nil` is "unknown" and
    # poisons whatever it touches; `:null` is the type of a bare NULL, which
    # takes on the type beside it.
    class Typer
      class Unsupported < StandardError; end

      NUMERIC_RANK = { "INTEGER" => 1, "BIGINT" => 2, "DOUBLE" => 3 }.freeze
      INTEGER_MAX = 2_147_483_647

      CAST_TYPES = {
        "integer" => "INTEGER", "int" => "INTEGER", "bigint" => "BIGINT", "double" => "DOUBLE",
        "varchar" => "VARCHAR", "char" => "VARCHAR", "boolean" => "BOOLEAN", "timestamp" => "TIMESTAMP"
      }.freeze

      FIXED_RESULT = {
        "BIGINT" => %w[count count_if row_number rank dense_rank ntile approx_distinct length year month day
                       hour minute second millisecond day_of_week dow day_of_year doy week quarter
                       to_milliseconds to_nanoseconds date_diff cardinality strpos],
        "DOUBLE" => %w[avg ln log2 log10 sqrt exp power pow stddev stddev_samp stddev_pop variance var_samp
                       var_pop to_unixtime],
        "VARCHAR" => %w[lower upper trim ltrim rtrim concat substr substring replace to_iso8601 split_part
                        regexp_extract regexp_replace lpad rpad reverse],
        "TIMESTAMP" => %w[bin ago now date_trunc date_add from_milliseconds from_nanoseconds from_unixtime
                          from_iso8601_timestamp],
        "BOOLEAN" => %w[regexp_like starts_with contains is_nan]
      }.flat_map { |type, names| names.map { |name| [name, type] } }.to_h.freeze

      # Same type as the first argument.
      FIRST_ARG = %w[min max min_by max_by arbitrary any_value first_value last_value lag lead nth_value abs round floor
                     ceil ceiling truncate sign nullif].freeze
      # Common supertype of every argument.
      ALL_ARGS = %w[coalesce greatest least].freeze

      # Words that end a relation rather than alias it.
      CLAUSE_WORDS = %w[on using where group having order limit offset fetch window join left right inner
                        outer full cross natural union except intersect].freeze
      SET_OPERATORS = %w[union except intersect].freeze

      TOKEN_RE = /
        (?<space>\s+|--[^\n]*|\/\*.*?\*\/)
        |(?<string>'(?:[^']|'')*')
        |(?<quoted>"(?:[^"]|"")*")
        |(?<interval>\d+(?:ns|us|ms|s|m|h|d)\b)
        |(?<number>(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)
        |(?<word>[A-Za-z_][A-Za-z0-9_]*)
        |(?<param>@[A-Za-z_]\w*|\?)
        |(?<op>::|<>|!=|<=|>=|\|\||->|=>|[(),.+\-*\/%=<>\[\];])
      /mx

      Token = Struct.new(:kind, :text)
      Relation = Struct.new(:name, :columns) do
        def lookup(column)
          columns.find { |name, _| name == column }&.last
        end

        def column?(column)
          columns.any? { |name, _| name == column }
        end
      end
      Scope = Struct.new(:relations, :ctes, :parent)

      # `catalog` maps (database, table) to the table's columns as ordered
      # [name, type] pairs, or nil when there is no such table.
      def initialize(sql, catalog)
        @sql = sql
        @catalog = catalog
      end

      # One type per output column, positionally, or nil when the statement is
      # beyond what this reads.
      def column_types
        @tokens = tokenize(@sql)
        @pos = 0
        columns = parse_query({}, nil)
        accept_op(";")
        raise Unsupported, "trailing #{peek&.text.inspect}" unless peek.nil?

        columns.map { |_, type| type == :null ? "UNKNOWN" : type }
      rescue Unsupported
        nil
      rescue StandardError => e
        # A typer bug must not fail a query SQLite can run; the values still type it.
        Log.event("typer_error", error: "#{e.class}: #{e.message}")
        nil
      end

      private

      # ------------------------------------------------------------ lexing

      def tokenize(sql)
        tokens = []
        pos = 0
        while pos < sql.length
          match = TOKEN_RE.match(sql, pos)
          raise Unsupported, "cannot read #{sql[pos, 10].inspect}" if match.nil? || match.begin(0) != pos

          pos = match.end(0)
          kind = %i[string quoted interval number word param op].find { |name| match[name] }
          tokens << Token.new(kind, match[kind]) if kind
        end
        tokens
      end

      def peek(offset = 0)
        @tokens[@pos + offset]
      end

      def advance
        token = peek or raise Unsupported, "unexpected end"
        @pos += 1
        token
      end

      def op?(text, offset = 0)
        token = peek(offset)
        token&.kind == :op && token.text == text
      end

      def accept_op(text)
        op?(text) && advance
      end

      def expect_op(text)
        accept_op(text) or raise Unsupported, "expected #{text.inspect}, got #{peek&.text.inspect}"
      end

      def kw?(*words, offset: 0)
        token = peek(offset)
        token&.kind == :word && words.include?(token.text.downcase)
      end

      def accept_kw(*words)
        kw?(*words) && advance
      end

      def expect_kw(word)
        accept_kw(word) or raise Unsupported, "expected #{word}, got #{peek&.text.inspect}"
      end

      # Trino folds identifiers, quoted or not, to lowercase.
      def identifier
        raw_identifier.downcase
      end

      # Database and table names are matched against the catalog as written.
      def raw_identifier
        token = advance
        case token.kind
        when :word then token.text
        when :quoted then token.text[1..-2].gsub('""', '"')
        else raise Unsupported, "expected an identifier, got #{token.text.inspect}"
        end
      end

      def identifier?
        %i[word quoted].include?(peek&.kind)
      end

      # Skips to the next depth-0 token satisfying the block, or to a closing
      # paren that belongs to an enclosing construct.
      def skip_until
        depth = 0
        until peek.nil?
          return if depth.zero? && (op?(")") || yield)

          depth += 1 if op?("(") || op?("[")
          depth -= 1 if op?(")") || op?("]")
          advance
        end
      end

      # ---------------------------------------------------------- queries

      def parse_query(ctes, parent)
        ctes = parse_with(ctes, parent) if kw?("with")
        columns = parse_query_term(ctes, parent)
        while accept_kw(*SET_OPERATORS)
          accept_kw("all", "distinct")
          columns = union(columns, parse_query_term(ctes, parent))
        end
        # ORDER BY / LIMIT / OFFSET of the whole query change no type.
        skip_until { false }
        columns
      end

      def parse_with(ctes, parent)
        advance
        raise Unsupported, "WITH RECURSIVE" if kw?("recursive")

        ctes = ctes.dup
        loop do
          name = identifier
          names = op?("(") ? identifier_list : nil
          expect_kw("as")
          expect_op("(")
          ctes[name] = rename(parse_query(ctes, parent), names)
          expect_op(")")
          break unless accept_op(",")
        end
        ctes
      end

      def parse_query_term(ctes, parent)
        return parse_select(ctes, parent) unless accept_op("(")

        columns = parse_query(ctes, parent)
        expect_op(")")
        columns
      end

      # The select list names columns of relations that come after it, so its
      # items are set aside as token spans and typed once FROM is read.
      def parse_select(ctes, parent)
        expect_kw("select")
        accept_kw("distinct", "all")
        spans = select_item_spans
        relations = kw?("from") ? parse_from(ctes, parent) : []
        skip_until { kw?(*SET_OPERATORS) }

        scope = Scope.new(relations, ctes, parent)
        spans.each_with_index.flat_map { |span, index| type_select_item(span, scope, index) }
      end

      def select_item_spans
        spans = [[]]
        depth = 0
        while (token = peek)
          break if depth.zero? && (op?(")") || kw?("from", *SET_OPERATORS, "where", "group", "having",
                                                     "order", "limit", "offset", "window"))

          depth += 1 if op?("(") || op?("[")
          depth -= 1 if op?(")") || op?("]")
          if depth.zero? && op?(",")
            spans << []
          else
            spans.last << token
          end
          advance
        end
        spans
      end

      def type_select_item(span, scope, index)
        with_tokens(span) do
          next star_columns(scope) if op?("*") || (identifier? && op?(".", 1) && op?("*", 2))

          begin
            name, type = parse_expression_with_name(scope)
            name = identifier if accept_kw("as") || identifier?
            raise Unsupported, "select item #{peek.text.inspect}" unless peek.nil?
          rescue Unsupported
            # One item beyond this reader costs that column, not the query's.
            name = span[-1].text.downcase if span.size > 2 && span[-2].text.casecmp?("as")
            type = nil
          end
          [[name || "_col#{index}", type]]
        end
      end

      def star_columns(scope)
        qualifier = op?("*") ? nil : identifier
        advance if qualifier
        advance
        relations = scope.relations.select { |relation| qualifier.nil? || relation.name == qualifier }
        raise Unsupported, "* over #{qualifier}" if relations.empty?

        relations.flat_map(&:columns)
      end

      def with_tokens(tokens)
        saved = [@tokens, @pos]
        @tokens = tokens
        @pos = 0
        yield
      ensure
        @tokens, @pos = saved
      end

      def parse_from(ctes, parent)
        advance
        relations = [parse_relation(ctes, parent)]
        loop do
          if accept_op(",")
            relations << parse_relation(ctes, parent)
          elsif kw?("natural", "inner", "left", "right", "full", "cross", "join")
            advance until accept_kw("join")
            relations << parse_relation(ctes, parent)
            skip_until { op?(",") || kw?(*CLAUSE_WORDS - %w[on using]) } if accept_kw("on", "using")
          else
            break
          end
        end
        relations
      end

      def parse_relation(ctes, parent)
        raise Unsupported, "UNNEST / LATERAL" if kw?("unnest", "lateral")

        if accept_op("(")
          raise Unsupported, "parenthesised join" unless kw?("select", "with") || op?("(")

          columns = parse_query(ctes, parent)
          expect_op(")")
          name, names = relation_alias
          return Relation.new(name, rename(columns, names))
        end

        parts = [raw_identifier]
        parts << raw_identifier while accept_op(".")
        columns = relation_columns(parts, ctes)
        name, names = relation_alias
        Relation.new(name || parts.last.split(".").last.downcase, rename(columns, names))
      end

      # A CTE name, `db.table`, or the collapsed `"db.table"`.
      def relation_columns(parts, ctes)
        return ctes[parts.first.downcase] if parts.size == 1 && ctes.key?(parts.first.downcase)

        database, table = parts.size == 1 ? parts.first.split(".", 2) : parts
        columns = (@catalog.call(database, table) if parts.size <= 2 && table)
        raise Unsupported, "unknown relation #{parts.join('.')}" if columns.nil?

        columns.map { |name, type| [name.downcase, type] }
      end

      def relation_alias
        if accept_kw("as") || (identifier? && !kw?(*CLAUSE_WORDS))
          name = identifier
          [name, op?("(") ? identifier_list : nil]
        else
          [nil, nil]
        end
      end

      def identifier_list
        expect_op("(")
        names = [identifier]
        names << identifier while accept_op(",")
        expect_op(")")
        names
      end

      def rename(columns, names)
        return columns if names.nil?
        raise Unsupported, "column alias count" unless names.size == columns.size

        names.zip(columns.map(&:last))
      end

      def union(left, right)
        raise Unsupported, "set operation width" unless left.size == right.size

        left.zip(right).map { |(name, a), (_, b)| [name, common(a, b)] }
      end

      # -------------------------------------------------------------- types

      def common(left, right)
        return right if left == :null
        return left if right == :null
        return nil if left.nil? || right.nil?
        return left if left == right

        numeric(left, right)
      end

      def numeric(left, right)
        return nil unless NUMERIC_RANK.key?(left) && NUMERIC_RANK.key?(right)

        NUMERIC_RANK[left] >= NUMERIC_RANK[right] ? left : right
      end

      def arithmetic(left, right)
        left = right if left == :null
        right = left if right == :null
        return :null if left == :null

        numeric(left, right)
      end

      # ---------------------------------------------------------- expressions

      # An item that is just a column reference is named after the column.
      def parse_expression_with_name(scope)
        start = @pos
        type = expression(scope)
        name = @reference[:name] if @reference && @reference[:span] == (start...@pos)
        [name, type]
      end

      def expression(scope)
        type = conjunction(scope)
        type = (conjunction(scope) && "BOOLEAN") while accept_kw("or")
        type
      end

      def conjunction(scope)
        type = negation(scope)
        type = (negation(scope) && "BOOLEAN") while accept_kw("and")
        type
      end

      def negation(scope)
        return negation(scope) && "BOOLEAN" if accept_kw("not")

        predicate(scope)
      end

      def predicate(scope)
        type = concatenation(scope)
        loop do
          if %w[= <> != < > <= >=].any? { |operator| accept_op(operator) }
            accept_kw("any", "all", "some")
            concatenation(scope)
          elsif accept_kw("is")
            accept_kw("not")
            if accept_kw("distinct")
              expect_kw("from")
              concatenation(scope)
            else
              expect_kw("null")
            end
          elsif kw?("between") || (kw?("not") && kw?("between", offset: 1))
            accept_kw("not")
            advance
            concatenation(scope)
            expect_kw("and")
            concatenation(scope)
          elsif kw?("in", "like") || (kw?("not") && kw?("in", "like", offset: 1))
            accept_kw("not")
            advance.text.casecmp?("in") ? in_list(scope) : like_pattern(scope)
          else
            return type
          end
          type = "BOOLEAN"
        end
      end

      def in_list(scope)
        expect_op("(")
        if kw?("select", "with")
          parse_query(scope.ctes, scope)
        else
          expression(scope)
          expression(scope) while accept_op(",")
        end
        expect_op(")")
      end

      def like_pattern(scope)
        concatenation(scope)
        concatenation(scope) if accept_kw("escape")
      end

      def concatenation(scope)
        type = additive(scope)
        type = (additive(scope) && "VARCHAR") while accept_op("||")
        type
      end

      def additive(scope)
        type = multiplicative(scope)
        type = arithmetic(type, multiplicative(scope)) while accept_op("+") || accept_op("-")
        type
      end

      def multiplicative(scope)
        type = unary(scope)
        type = arithmetic(type, unary(scope)) while accept_op("*") || accept_op("/") || accept_op("%")
        type
      end

      def unary(scope)
        return unary(scope) if accept_op("-") || accept_op("+")

        type = primary(scope)
        while accept_op("[")
          expression(scope)
          expect_op("]")
          type = nil
        end
        type
      end

      def primary(scope)
        token = peek or raise Unsupported, "unexpected end"
        case token.kind
        when :number
          advance
          token.text.match?(/\A\d+\z/) ? integer_literal(token.text) : nil
        when :string then advance && "VARCHAR"
        when :interval, :param then advance && nil
        when :quoted then column_reference(scope)
        when :word then word(scope)
        when :op
          raise Unsupported, "unexpected #{token.text.inspect}" unless op?("(")

          parenthesised(scope)
        end
      end

      # Trino types an integer literal INTEGER when it fits in 32 bits.
      def integer_literal(text)
        Integer(text, 10) <= INTEGER_MAX ? "INTEGER" : "BIGINT"
      end

      def parenthesised(scope)
        advance
        if kw?("select", "with")
          columns = parse_query(scope.ctes, scope)
          expect_op(")")
          return columns.size == 1 ? columns.first.last : nil
        end

        type = expression(scope)
        if accept_op(",")
          expression(scope)
          expression(scope) while accept_op(",")
          type = nil
        end
        expect_op(")")
        type
      end

      def word(scope)
        text = peek.text.downcase
        case text
        when "true", "false" then advance && "BOOLEAN"
        when "null" then advance && :null
        when "case" then case_expression(scope)
        when "cast", "try_cast" then cast(scope)
        when "exists"
          advance
          parenthesised(scope) && "BOOLEAN"
        when "current_timestamp", "localtimestamp" then advance && "TIMESTAMP"
        when "extract"
          return column_reference(scope) unless op?("(", 1)

          advance
          advance
          identifier
          expect_kw("from")
          expression(scope)
          expect_op(")")
          "BIGINT"
        else
          if peek(1)&.kind == :string && %w[timestamp date time interval].include?(text)
            typed_literal(text)
          elsif op?("(", 1)
            function_call(scope)
          elsif text == "array" && op?("[", 1)
            advance
            advance
            skip_until { op?("]") }
            expect_op("]")
            nil
          else
            column_reference(scope)
          end
        end
      end

      def typed_literal(text)
        advance
        advance
        if text == "interval"
          advance while kw?("year", "month", "day", "hour", "minute", "second", "to")
          return nil
        end
        text == "timestamp" ? "TIMESTAMP" : nil
      end

      def case_expression(scope)
        advance
        expression(scope) unless kw?("when")
        type = :null
        while accept_kw("when")
          expression(scope)
          expect_kw("then")
          type = common(type, expression(scope))
        end
        type = common(type, expression(scope)) if accept_kw("else")
        expect_kw("end")
        type
      end

      def cast(scope)
        advance
        expect_op("(")
        expression(scope)
        expect_kw("as")
        name = identifier
        # varchar(10), decimal(10, 2), double precision
        if accept_op("(")
          skip_until { false }
          expect_op(")")
        end
        accept_kw("precision")
        expect_op(")")
        CAST_TYPES[name]
      end

      def function_call(scope)
        name = identifier
        expect_op("(")
        args = function_arguments(scope)
        expect_op(")")
        window_clauses
        function_type(name, args)
      end

      def function_arguments(scope)
        return [] if op?(")")
        return [advance && "BIGINT"] if op?("*") && op?(")", 1)

        accept_kw("distinct", "all")
        args = [expression(scope)]
        args << expression(scope) while accept_op(",")
        raise Unsupported, "lambda" if op?("->")

        skip_until { false } if accept_kw("order")
        args
      end

      def window_clauses
        if accept_kw("filter")
          expect_op("(")
          skip_until { false }
          expect_op(")")
        end
        expect_kw("nulls") if accept_kw("ignore", "respect")
        return unless accept_kw("over")

        if accept_op("(")
          skip_until { false }
          expect_op(")")
        else
          identifier
        end
      end

      def function_type(name, args)
        return FIXED_RESULT[name] if FIXED_RESULT.key?(name)
        return args.first == :null ? :null : args.first if FIRST_ARG.include?(name)
        return args.reduce(:null) { |type, arg| common(type, arg) } if ALL_ARGS.include?(name)

        case name
        when "sum" then { "INTEGER" => "BIGINT", "BIGINT" => "BIGINT", "DOUBLE" => "DOUBLE" }[args.first]
        when "if" then common(args[1], args[2] || :null)
        when "mod" then arithmetic(args[0], args[1])
        end
      end

      def column_reference(scope)
        start = @pos
        parts = [identifier]
        parts << identifier while accept_op(".")
        parts = ["measure_value::#{identifier}"] if parts == ["measure_value"] && accept_op("::")
        @reference = { name: parts.last, span: start...@pos }
        resolve(parts, scope)
      end

      # `db.table.column` scopes as `table.column`: the relation in scope is the
      # table's bare name, as in the rewriter.
      def resolve(parts, scope)
        column = parts.last
        qualifier = parts[-2]
        while scope
          candidates = scope.relations.select do |relation|
            (qualifier.nil? || relation.name == qualifier) && relation.column?(column)
          end
          return candidates.first.lookup(column) if candidates.size == 1
          return nil if candidates.size > 1

          scope = scope.parent
        end
        nil
      end
    end
  end
end
