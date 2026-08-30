# frozen_string_literal: true

require "base64"
require "sqlite3"
require "xxhash"

module TimestreamLocal
  module Query
    # Timestream's dialect is Trino's. SQLite is not, so the gap is closed with
    # Ruby UDFs registered on the connection. Interval arguments arrive as
    # nanosecond integers -- the rewriter has already turned `1h` into
    # 3600000000000 by the time SQLite sees the call.
    module Functions
      UNIT_NANOS = {
        "nanosecond" => 1, "microsecond" => 1_000, "millisecond" => 1_000_000,
        "second" => 1_000_000_000, "minute" => 60_000_000_000, "hour" => 3_600_000_000_000,
        "day" => 86_400_000_000_000, "week" => 604_800_000_000_000
      }.freeze

      module_function

      def install(db)
        scalar(db, "now", 0) { Types.now_iso }
        scalar(db, "current_timestamp_ns", 0) { Types.now_iso }

        scalar(db, "ago", 1) do |interval_ns|
          Types.ns_to_iso(now_ns - Integer(interval_ns))
        end

        scalar(db, "bin", 2) do |timestamp, interval_ns|
          next nil if timestamp.nil?

          width = Integer(interval_ns)
          next nil if width <= 0

          nanos = Types.iso_to_ns(timestamp)
          Types.ns_to_iso(nanos - nanos.modulo(width))
        end

        scalar(db, "date_trunc", 2) do |unit, timestamp|
          next nil if timestamp.nil?

          truncate(unit.to_s.downcase, Types.iso_to_ns(timestamp))
        end

        scalar(db, "date_add", 3) do |unit, amount, timestamp|
          next nil if timestamp.nil?

          step = UNIT_NANOS.fetch(normalize_unit(unit)) { raise ValidationException, "Unknown unit #{unit}" }
          Types.ns_to_iso(Types.iso_to_ns(timestamp) + (Integer(amount) * step))
        end

        scalar(db, "date_diff", 3) do |unit, from, to|
          next nil if from.nil? || to.nil?

          step = UNIT_NANOS.fetch(normalize_unit(unit)) { raise ValidationException, "Unknown unit #{unit}" }
          (Types.iso_to_ns(to) - Types.iso_to_ns(from)) / step
        end

        scalar(db, "from_milliseconds", 1) { |ms| ms.nil? ? nil : Types.ns_to_iso(Integer(ms) * 1_000_000) }
        scalar(db, "from_nanoseconds", 1) { |ns| ns.nil? ? nil : Types.ns_to_iso(Integer(ns)) }
        scalar(db, "from_unixtime", 1) { |s| s.nil? ? nil : Types.ns_to_iso((Float(s) * 1_000_000_000).round) }
        # Trino renders a timestamp with a `T` separator, keeping the full
        # precision of the value -- nanoseconds here. The result is a varchar.
        scalar(db, "to_iso8601", 1) do |timestamp|
          next nil if timestamp.nil?

          Types.ns_to_iso(Types.iso_to_ns(timestamp)).sub(" ", "T")
        end

        scalar(db, "to_milliseconds", 1) { |ts| ts.nil? ? nil : Types.iso_to_ns(ts) / 1_000_000 }
        scalar(db, "to_nanoseconds", 1) { |ts| ts.nil? ? nil : Types.iso_to_ns(ts) }
        scalar(db, "to_unixtime", 1) { |ts| ts.nil? ? nil : Types.iso_to_ns(ts) / 1_000_000_000.0 }

        %w[year month day hour minute second].each do |part|
          scalar(db, part, 1) do |timestamp|
            next nil if timestamp.nil?

            Time.parse("#{timestamp} UTC").public_send(part == "day" ? :day : part.to_sym)
          end
        end

        scalar(db, "sqrt", 1) { |x| x.nil? ? nil : Math.sqrt(Float(x)) }
        scalar(db, "pow", 2) { |x, y| x.nil? || y.nil? ? nil : Float(x)**Float(y) }
        scalar(db, "regexp_like", 2) { |value, pattern| value.nil? ? nil : (value.to_s.match?(Regexp.new(pattern)) ? 1 : 0) }

        # Timestamp arithmetic. The rewriter turns `time + 1m` into a call to
        # this, because SQLite would otherwise coerce the timestamp string to a
        # number and silently return nonsense.
        scalar(db, "date_add_ns", 2) do |timestamp, nanos|
          next nil if timestamp.nil? || nanos.nil?

          Types.ns_to_iso(Types.iso_to_ns(timestamp) + Integer(nanos))
        end

        # Back the CAST rewrites. SQLite would otherwise coerce these to NUMERIC
        # and return a number for both.
        scalar(db, "to_timestamp", 1) { |value| value.nil? ? nil : Types.timestamp_value_to_iso(value) }
        scalar(db, "to_boolean", 1) { |value| value.nil? ? nil : (Types.parse_bool(value) ? 1 : 0) }

        # `IF` happens to exist in the SQLite the sqlite3 gem vendors, but it is
        # not in SQLite's documented function set -- registering it explicitly
        # keeps it from disappearing under a gem bump.
        scalar(db, "if", 3) { |condition, when_true, when_false| truthy?(condition) ? when_true : when_false }

        install_hashing(db)
        install_aggregates(db)
      end

      # Dimension hashing. A client that keys rows by a hash computes it both in
      # SQL and in its own code, so the two have to agree exactly:
      #   to_base64(xxhash64(cast(<varchar> as varbinary)))
      # must agree byte for byte with Ruby's
      #   Base64.strict_encode64([XXhash.xxh64(s)].pack("Q>"))
      # so the hash is XXH64 seed 0, packed big-endian, standard base64.
      def install_hashing(db)
        scalar(db, "xxhash64", 1) do |value|
          next nil if value.nil?

          # A non-string here means the varbinary cast was lost somewhere and we
          # would be hashing a coerced number. That produces a wrong-but-plausible
          # hash rather than an error, so refuse it instead.
          unless value.is_a?(String)
            raise ValidationException,
                  "xxhash64 expects a varbinary argument, got #{value.class}; " \
                  "wrap the argument in CAST(... AS varbinary)"
          end

          SQLite3::Blob.new([XXhash.xxh64(value)].pack("Q>"))
        end

        scalar(db, "to_base64", 1) { |value| value.nil? ? nil : Base64.strict_encode64(value.to_s) }
        scalar(db, "from_base64", 1) do |value|
          value.nil? ? nil : SQLite3::Blob.new(Base64.strict_decode64(value.to_s))
        end
      end

      def install_aggregates(db)
        # Trino returns 0, not NULL, for a count over an empty group.
        aggregate(db, "count_if", 1) do
          step { |ctx, condition| ctx[:count] = (ctx[:count] || 0) + (Functions.truthy?(condition) ? 1 : 0) }
          finalize { |ctx| ctx.result = ctx[:count] || 0 }
        end

        # max_by(value, key) -- the value from the row with the largest key. The
        # winning value may legitimately be NULL, so the tracked entry is a pair
        # and its presence, not its content, marks a seen row.
        aggregate(db, "max_by", 2) do
          step { |ctx, value, key| Functions.track_extreme(ctx, value, key, 1) }
          finalize { |ctx| ctx.result = ctx[:best]&.last }
        end

        aggregate(db, "min_by", 2) do
          step { |ctx, value, key| Functions.track_extreme(ctx, value, key, -1) }
          finalize { |ctx| ctx.result = ctx[:best]&.last }
        end

        aggregate(db, "create_time_series", 2) do
          step { |ctx, time, value| (ctx[:points] ||= []) << [time, value] }
          finalize { |ctx| ctx.result = TimeSeries.encode(ctx[:points] || []) }
        end
      end

      # SQLite hands each GROUP BY group its own FunctionProxy, so per-group
      # state can live directly on the context.
      def aggregate(db, name, arity, &definition)
        db.create_aggregate(name, arity, &definition)
      end

      def truthy?(value)
        !(value.nil? || value == 0 || value == false)
      end

      def track_extreme(ctx, value, key, direction)
        return if key.nil?

        best = ctx[:best]
        ctx[:best] = [key, value] if best.nil? || compare(key, best.first) == direction
      end

      # Keys are usually the fixed-width timestamp strings, which order the same
      # lexicographically as they do temporally.
      def compare(left, right)
        return left <=> right if left.is_a?(Numeric) && right.is_a?(Numeric)
        return left <=> right if left.instance_of?(right.class)

        left.to_s <=> right.to_s
      end

      def scalar(db, name, arity, &body)
        db.create_function(name, arity) do |func, *args|
          func.result = body.call(*args)
        rescue StandardError => e
          func.result = nil
          raise QueryExecutionException, "#{name}: #{e.message}"
        end
      end

      def now_ns
        (Time.now.to_r * 1_000_000_000).to_i
      end

      def normalize_unit(unit)
        unit.to_s.downcase.sub(/s\z/, "")
      end

      def truncate(unit, nanos)
        case normalize_unit(unit)
        when "nanosecond" then Types.ns_to_iso(nanos)
        when "microsecond", "millisecond", "second", "minute", "hour", "day", "week"
          width = UNIT_NANOS.fetch(normalize_unit(unit))
          Types.ns_to_iso(nanos - nanos.modulo(width))
        when "month"
          t = Time.at(nanos / 1_000_000_000).utc
          Types.ns_to_iso(Time.utc(t.year, t.month, 1).to_i * 1_000_000_000)
        when "year"
          t = Time.at(nanos / 1_000_000_000).utc
          Types.ns_to_iso(Time.utc(t.year, 1, 1).to_i * 1_000_000_000)
        else
          raise ValidationException, "Unknown truncation unit #{unit}"
        end
      end
    end
  end
end
