# frozen_string_literal: true

module TimestreamLocal
  module Query
    # Timestamps are stored as fixed-width text, which sorts lexicographically in
    # the same order it sorts temporally -- but only while both sides of a
    # comparison are fixed width. A literal is not:
    #
    #   '2026-03-22 17:06:00'  <  '2026-03-22 17:06:00.000000000'
    #
    # because it is shorter. So `time <= '2026-03-22 17:06:00'` excludes a row
    # stored at exactly that instant and `time = '...'` never matches anything,
    # while `>=` happens to come out right -- which is what makes it hide. Every
    # range's lower bound works and only the upper bound is wrong.
    #
    # Timestamp-shaped literals are therefore padded to the stored width before
    # the comparison runs. Only literals actually compared against a timestamp
    # are touched, so a VARCHAR dimension that happens to hold a date-shaped
    # string still compares as text.
    module TimestampLiterals
      LITERAL = /'(?:[^']|'')*'/
      BACKTICKED = /`(?:[^`]|``)*`/
      SIMPLE_NAME = /[A-Za-z_]\w*/
      COLUMN = /(?:#{BACKTICKED}|#{SIMPLE_NAME})(?:\s*\.\s*(?:#{BACKTICKED}|#{SIMPLE_NAME}))?/
      FUNCTION_CALL = /#{SIMPLE_NAME}\s*\((?:[^()]|\([^()]*\))*\)/
      OPERAND = /(?:#{FUNCTION_CALL}|#{COLUMN})/
      COMPARISON = /(?:<=|>=|<>|!=|=|<|>)/

      # Functions that yield a timestamp, so a literal compared against one is
      # being compared against a timestamp.
      TIMESTAMP_FUNCTIONS = %w[
        bin date_trunc date_add date_add_ns ago now current_timestamp_ns
        from_milliseconds from_nanoseconds from_unixtime
      ].freeze

      # `2026-03-22`, `2026-03-22 17:06`, `2026-03-22 17:06:00`, with or without a
      # fractional part. Missing components are filled before the fraction is
      # padded -- padding the text alone would turn `17:06` into `17:06:.000000`.
      SHAPE = /\A(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?(?:\.(\d{1,9}))?)?\z/

      module_function

      def normalize(sql, timestamp_columns)
        columns = Array(timestamp_columns)

        sql = sql.gsub(/(#{OPERAND})(\s*#{COMPARISON}\s*)(#{LITERAL})/) do
          operand, operator, literal = Regexp.last_match.captures
          "#{operand}#{operator}#{timestamp?(operand, columns) ? pad(literal) : literal}"
        end

        sql = sql.gsub(/(#{LITERAL})(\s*#{COMPARISON}\s*)(#{OPERAND})/) do
          literal, operator, operand = Regexp.last_match.captures
          "#{timestamp?(operand, columns) ? pad(literal) : literal}#{operator}#{operand}"
        end

        sql.gsub(/(#{OPERAND})(\s+between\s+)(#{LITERAL})(\s+and\s+)(#{LITERAL})/i) do
          operand, between, low, conjunction, high = Regexp.last_match.captures
          low, high = [pad(low), pad(high)] if timestamp?(operand, columns)
          "#{operand}#{between}#{low}#{conjunction}#{high}"
        end
      end

      def timestamp?(operand, columns)
        call = operand[/\A(#{SIMPLE_NAME})\s*\(/, 1]
        return TIMESTAMP_FUNCTIONS.include?(call.downcase) if call

        columns.include?(unquote(operand.split(".").last.to_s.strip))
      end

      def pad(literal)
        match = SHAPE.match(literal[1..-2]) or return literal

        date, hour, minute, second, fraction = match.captures
        format("'%s %s:%s:%s.%s'", date, hour || "00", minute || "00", second || "00",
               (fraction || "").ljust(9, "0")[0, 9])
      end

      def unquote(token)
        token.start_with?("`") ? token[1..-2].gsub("``", "`") : token
      end
    end
  end
end
