# frozen_string_literal: true

require "time"

module TimestreamLocal
  # Conversions between the Timestream wire types (everything is a string on
  # the wire) and the values we hand to SQLite.
  #
  # Timestamps are stored as fixed-width UTC text -- "2021-12-01 19:00:00.000000000".
  # That format sorts lexicographically in the same order it sorts temporally, so
  # range predicates and ORDER BY work without a native timestamp type, and it is
  # byte-for-byte what Timestream returns in a query result.
  module Types
    module_function

    SCALAR_TYPES = %w[DOUBLE BIGINT VARCHAR BOOLEAN TIMESTAMP].freeze
    MEASURE_TYPES = (SCALAR_TYPES + %w[MULTI]).freeze
    TIME_UNITS = {
      "SECONDS" => 1_000_000_000,
      "MILLISECONDS" => 1_000_000,
      "MICROSECONDS" => 1_000,
      "NANOSECONDS" => 1
    }.freeze

    TIMESTAMP_RE = /\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{9}\z/

    def sqlite_decl(ts_type)
      case ts_type
      when "DOUBLE" then "REAL"
      when "BIGINT" then "INTEGER"
      when "BOOLEAN" then "INTEGER"
      else "TEXT"
      end
    end

    def ns_to_iso(nanos)
      secs, rem = Integer(nanos).divmod(1_000_000_000)
      format("%s.%09d", Time.at(secs).utc.strftime("%Y-%m-%d %H:%M:%S"), rem)
    end

    def iso_to_ns(str)
      t = Time.parse(str.match?(/[zZ]|[+-]\d{2}:?\d{2}\z/) ? str : "#{str} UTC")
      (t.to_i * 1_000_000_000) + t.nsec
    end

    def now_iso
      ns_to_iso((Time.now.to_r * 1_000_000_000).to_i)
    end

    # A record's Time is a string in the unit given by TimeUnit (default ms).
    def record_time_to_iso(value, unit)
      unit ||= "MILLISECONDS"
      multiplier = TIME_UNITS[unit] or
        raise ValidationException, "Invalid TimeUnit #{unit.inspect}"
      raise ValidationException, "Time must be an integer string" unless value.to_s.match?(/\A-?\d+\z/)

      ns_to_iso(Integer(value, 10) * multiplier)
    end

    # A TIMESTAMP measure value arrives either as epoch nanoseconds or as a
    # datetime string; accept both and normalise.
    def timestamp_value_to_iso(value)
      value.to_s.match?(/\A-?\d+\z/) ? ns_to_iso(Integer(value, 10)) : ns_to_iso(iso_to_ns(value.to_s))
    end

    # Wire string -> value bound into SQLite.
    def coerce(ts_type, value)
      case ts_type
      when "DOUBLE"
        Float(value)
      when "BIGINT"
        Integer(value, 10)
      when "BOOLEAN"
        parse_bool(value) ? 1 : 0
      when "TIMESTAMP"
        timestamp_value_to_iso(value)
      when "VARCHAR"
        value.to_s
      else
        raise ValidationException, "Unsupported measure value type #{ts_type.inspect}"
      end
    rescue ArgumentError, TypeError
      raise ValidationException, "Value #{value.inspect} is not a valid #{ts_type}"
    end

    def parse_bool(value)
      case value.to_s.downcase
      when "true", "1" then true
      when "false", "0" then false
      else raise ValidationException, "Value #{value.inspect} is not a valid BOOLEAN"
      end
    end

    # SQLite value -> the string that goes in Datum#scalar_value.
    def format_scalar(value, ts_type)
      case value
      when nil then nil
      when Float then format_double(value)
      when Integer then ts_type == "BOOLEAN" ? (value.zero? ? "false" : "true") : value.to_s
      when true, false then value.to_s
      else value.to_s
      end
    end

    def format_double(float)
      return float.to_s if float.nan? || float.infinite?

      float == float.truncate && float.abs < 1e15 ? format("%.1f", float) : float.to_s
    end

    # Could this SQLite value have come out of a column declared `ts_type`?
    # Timestamps are always stored fixed width and booleans always as 0/1, so a
    # value that does not fit proves the column is a computed expression rather
    # than the stored column whose name it carries.
    def consistent?(ts_type, value)
      case ts_type
      when "TIMESTAMP" then value.is_a?(String) && value.match?(TIMESTAMP_RE)
      when "VARCHAR" then value.is_a?(String)
      when "BOOLEAN", "BIGINT" then value.is_a?(Integer)
      when "DOUBLE" then value.is_a?(Numeric)
      else true
      end
    end

    # Best-effort column typing for query results. SQLite is dynamically typed,
    # so a declared type from the catalog wins and we fall back to the value.
    def infer_type(value)
      case value
      when Float then "DOUBLE"
      when Integer then "BIGINT"
      when true, false then "BOOLEAN"
      when String then value.match?(TIMESTAMP_RE) ? "TIMESTAMP" : "VARCHAR"
      when nil then "UNKNOWN"
      else "VARCHAR"
      end
    end
  end
end
