# frozen_string_literal: true

module TimestreamLocal
  # Approximate metering figures: bytes scanned, bytes metered, bytes written.
  #
  # The real service charges for the bytes a query scanned out of its store.
  # There is no such store here and SQLite exposes no scan accounting, so these
  # are modelled from the rows a statement produced, at the size those values
  # occupy in this store. Two things follow, and both matter before asserting on
  # the numbers:
  #
  #   - An aggregate under-reports. `count(*)` over a million rows scans all of
  #     them and returns one, and one row is what gets counted here.
  #   - They are a plausible shape, not a cost estimate. Good for a consumer
  #     that reads, logs or asserts on the field; useless for predicting a bill.
  #
  # What they buy over the zeros they replace is that the fields move: a wider
  # result meters more than a narrow one, and nothing is free.
  module Metering
    # The real service meters a floor per query, so a trivial one is not free.
    # Keeping the floor is what makes a metered figure look metered rather than
    # look like the row count it was derived from.
    MINIMUM_METERED_BYTES = 10 * 1024 * 1024
    # Per row, for the parts of a record that are not its values: time, version,
    # and the store's own bookkeeping.
    ROW_OVERHEAD_BYTES = 16
    NUMBER_BYTES = 8
    BOOLEAN_BYTES = 1

    module_function

    # Rows as the store hands them back: raw scalars, with timestamps and
    # TIMESERIES values already text, which is what they cost here.
    def scanned_bytes(rows)
      rows.sum { |row| ROW_OVERHEAD_BYTES + row.sum { |value| value_bytes(value) } }
    end

    def metered_bytes(scanned)
      [scanned.to_i, MINIMUM_METERED_BYTES].max
    end

    # Records on their way into a table, in the shape WriteRecords takes them.
    # Dimension and attribute names are charged per record, as they are stored.
    def written_bytes(records)
      records.sum { |record| ROW_OVERHEAD_BYTES + record_bytes(record) }
    end

    def record_bytes(record)
      value_bytes(record["MeasureName"]) + value_bytes(record["Time"]) +
        value_bytes(record["MeasureValue"]) +
        pairs_bytes(record["Dimensions"], "Name", "Value") +
        pairs_bytes(record["MeasureValues"], "Name", "Value")
    end

    def pairs_bytes(pairs, name_key, value_key)
      Array(pairs).sum { |pair| value_bytes(pair[name_key]) + value_bytes(pair[value_key]) }
    end

    def value_bytes(value)
      case value
      when nil then 0
      when true, false then BOOLEAN_BYTES
      when Numeric then NUMBER_BYTES
      else value.to_s.bytesize
      end
    end
  end
end
