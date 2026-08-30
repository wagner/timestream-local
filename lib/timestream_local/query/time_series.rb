# frozen_string_literal: true

require "json"

module TimestreamLocal
  module Query
    # TIMESERIES is the one Timestream type that is not scalar: a column holds an
    # ordered list of (time, value) points rather than a single value.
    #
    # SQLite aggregates can only return a scalar, so `create_time_series` returns
    # its points as a marked JSON string and QueryApi turns that back into the
    # TimeSeriesValue wire shape. The marker is a NUL-delimited sentinel because
    # a NUL cannot occur in a Timestream VARCHAR, so a genuine string value can
    # never be mistaken for an encoded series. (The sqlite3 gem carries the byte
    # length through, so the NUL survives the round trip -- a plain prefix would
    # have been ambiguous with user data.)
    module TimeSeries
      MARKER = "\u0000timestream-local:timeseries\u0000"

      module_function

      # Points whose time is NULL are dropped: Timestream rejects null timestamps,
      # so `create_time_series(IF(v IS NULL, NULL, time), v)` is the documented
      # idiom for omitting a point.
      def encode(points)
        ordered = points.reject { |time, _| time.nil? }.sort_by { |time, _| time.to_s }
        MARKER + JSON.dump(ordered)
      end

      def encoded?(value)
        value.is_a?(String) && value.start_with?(MARKER)
      end

      def decode(value)
        JSON.parse(value[MARKER.length..])
      end
    end
  end
end
