# frozen_string_literal: true

require "base64"
require "xxhash"

require_relative "test_helper"

# The Trino-flavoured functions that are not simply SQLite functions under
# another name: dimension hashing, filtered counts, last-value rollups and
# TIMESERIES.
class QueryFunctionsTest < TimestreamTest
  BASE_TIME = Time.utc(2026, 1, 1, 0, 0, 0)

  # host=a carries a cpu gap at t1 -- the record at that minute writes only
  # memory, so cpu is NULL there and the TIMESERIES tests have a point to drop.
  def seed(database_name, table_name)
    records = [
      { host: "a", offset: 0, cpu: "1.0", memory: "10" },
      { host: "a", offset: 60, cpu: nil, memory: "11" },
      { host: "a", offset: 120, cpu: "3.0", memory: "12" },
      { host: "a", offset: 180, cpu: "4.0", memory: "13" },
      { host: "b", offset: 0, cpu: "9.0", memory: "20" }
    ].map do |row|
      values = [{ name: "memory", value: row[:memory], type: "BIGINT" }]
      values.unshift({ name: "cpu", value: row[:cpu], type: "DOUBLE" }) if row[:cpu]
      {
        dimensions: [{ name: "host", value: row[:host] }],
        measure_name: "metrics", measure_value_type: "MULTI", measure_values: values,
        time: millis(BASE_TIME + row[:offset])
      }
    end
    # Written out of order so the TIMESERIES ordering assertion means something.
    write_client.write_records(database_name: database_name, table_name: table_name,
                               records: records.reverse)
  end

  def query(sql)
    query_client.query(query_string: sql)
  end

  # ------------------------------------------------------------------ hashing

  # The definition of correct is the Ruby twin a client computes, so the twin is
  # computed here and compared rather than a literal being pasted in.
  def ruby_twin(string)
    Base64.strict_encode64([XXhash.xxh64(string)].pack("Q>"))
  end

  def test_xxhash64_matches_the_ruby_twin
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query(<<~SQL)
        SELECT to_base64(xxhash64(cast('host:' || CAST(host AS varchar) AS varbinary))) AS h
        FROM "#{database_name}"."#{table_name}"
        WHERE host = 'a' AND measure_name = 'metrics'
        GROUP BY host
      SQL

      assert_equal ruby_twin("host:a"), rows_as_hashes(response).first["h"]
    end
  end

  def test_xxhash64_pinned_vectors
    # Derived from the reference implementation, not copied from a description of
    # it: XXH64 seed 0, packed big-endian, standard base64 with padding.
    { "" => "70bbN1HY6Zk=", "a" => "0k7E8amMbls=",
      "provider:stripe,status:ok" => "aXikXkqPpks=" }.each do |input, expected|
      assert_equal expected, ruby_twin(input), "ruby twin drifted for #{input.inspect}"

      response = query("SELECT to_base64(xxhash64(cast('#{input}' AS varbinary))) AS h")
      assert_equal expected, rows_as_hashes(response).first["h"], "SQL drifted for #{input.inspect}"
    end
  end

  # SQLite has no varbinary and its affinity rules quietly resolve the cast to
  # NUMERIC, which would hash the string "0" and return a plausible wrong answer
  # for every row. Guarding the rewrite is the whole point of this test.
  def test_varbinary_cast_is_not_silently_numeric
    response = query("SELECT typeof(cast('a' AS varbinary)) AS t")
    assert_equal "blob", rows_as_hashes(response).first["t"]
  end

  # Belt and braces for the same failure: if the cast is ever lost, hashing must
  # fail loudly rather than return the hash of a coerced number.
  def test_xxhash64_rejects_a_non_binary_argument
    error = assert_raises(Aws::TimestreamQuery::Errors::QueryExecutionException) do
      query("SELECT xxhash64(42) AS h")
    end
    assert_match(/varbinary/, error.message)
  end

  # ------------------------------------------------------------------ ISO 8601

  def test_to_iso8601_renders_the_t_separated_form
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query_client.query(query_string: <<~SQL)
        SELECT to_iso8601(time) AS iso
        FROM "#{database_name}"."#{table_name}"
        WHERE host = 'b'
      SQL

      # `T` separator, and the full nanosecond precision is kept.
      assert_equal "2026-01-01T00:00:00.000000000", rows_as_hashes(response).first["iso"]
      assert_equal "VARCHAR", response.column_info.first.type.scalar_type
    end
  end

  # An export selects `to_iso8601(time) AS time`, aliasing a computed VARCHAR
  # straight over the TIMESTAMP column it reads. The alias must not inherit the
  # stored column's type from the catalog.
  def test_to_iso8601_aliased_over_the_time_column
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query_client.query(query_string: <<~SQL)
        SELECT to_iso8601(time) AS time
        FROM "#{database_name}"."#{table_name}"
        WHERE host = 'b'
      SQL

      assert_equal "VARCHAR", response.column_info.first.type.scalar_type
      assert_equal "2026-01-01T00:00:00.000000000", rows_as_hashes(response).first["time"]
    end
  end

  # The stored column itself must still be reported from the catalog.
  def test_the_real_time_column_keeps_its_declared_type
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query_client.query(
        query_string: %(SELECT time FROM "#{database_name}"."#{table_name}" WHERE host = 'b')
      )

      assert_equal "TIMESTAMP", response.column_info.first.type.scalar_type
      assert_equal "2026-01-01 00:00:00.000000000", rows_as_hashes(response).first["time"]
    end
  end

  # ------------------------------------------------------- filtered aggregates

  def test_count_if_counts_only_matching_rows
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query(<<~SQL)
        SELECT host, count_if(memory > 11) AS busy
        FROM "#{database_name}"."#{table_name}"
        GROUP BY host ORDER BY host
      SQL

      assert_equal([{ "host" => "a", "busy" => "2" }, { "host" => "b", "busy" => "1" }],
                   rows_as_hashes(response))
    end
  end

  def test_count_if_returns_zero_for_an_empty_group
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query(<<~SQL)
        SELECT count_if(memory > 11) AS busy
        FROM "#{database_name}"."#{table_name}"
        WHERE host = 'nobody'
      SQL

      # Trino answers 0 here, not NULL.
      assert_equal "0", rows_as_hashes(response).first["busy"]
    end
  end

  def test_max_by_and_min_by_pick_the_value_at_the_extreme_key
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query(<<~SQL)
        SELECT max_by(memory, time) AS latest, min_by(memory, time) AS earliest
        FROM "#{database_name}"."#{table_name}"
        WHERE host = 'a'
      SQL

      row = rows_as_hashes(response).first
      assert_equal "13", row["latest"]
      assert_equal "10", row["earliest"]
    end
  end

  # ---------------------------------------------------------------- TIMESERIES

  def time_series_column(response)
    response.column_info.first
  end

  def test_create_time_series_returns_the_time_series_wire_shape
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query(<<~SQL)
        SELECT create_time_series(time, memory) AS series
        FROM "#{database_name}"."#{table_name}"
        WHERE host = 'a'
      SQL

      column = time_series_column(response)
      assert_nil column.type.scalar_type
      info = column.type.time_series_measure_value_column_info
      refute_nil info, "expected a TimeSeriesMeasureValueColumnInfo"
      assert_equal "BIGINT", info.type.scalar_type

      points = response.rows.first.data.first.time_series_value
      assert_equal 4, points.size
      # Ordered by time regardless of the order rows were written.
      assert_equal points.map(&:time).sort, points.map(&:time)
      assert_equal %w[10 11 12 13], points.map { |point| point.value.scalar_value }
      assert_equal "2026-01-01 00:00:00.000000000", points.first.time
    end
  end

  # Callers write create_time_series(IF(v IS NULL, NULL, time), v),
  # because Timestream rejects a null timestamp -- passing NULL as the time is
  # how a point is dropped.
  def test_create_time_series_drops_points_with_a_null_time
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query(<<~SQL)
        SELECT create_time_series(IF(cpu IS NULL, NULL, time), cpu) AS series
        FROM "#{database_name}"."#{table_name}"
        WHERE host = 'a'
      SQL

      assert_equal "DOUBLE", time_series_column(response).type.time_series_measure_value_column_info.type.scalar_type
      points = response.rows.first.data.first.time_series_value
      assert_equal %w[1.0 3.0 4.0], points.map { |point| point.value.scalar_value }
      refute_includes points.map(&:time), "2026-01-01 00:01:00.000000000"
    end
  end

  # An alias colliding with a real column must not inherit that column's type.
  def test_create_time_series_aliased_over_a_real_column_name
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query(<<~SQL)
        SELECT create_time_series(time, cpu) AS cpu
        FROM "#{database_name}"."#{table_name}"
        WHERE host = 'b'
      SQL

      column = time_series_column(response)
      assert_nil column.type.scalar_type
      assert_equal "DOUBLE", column.type.time_series_measure_value_column_info.type.scalar_type
    end
  end

  # --------------------------------------------------- interval arithmetic

  def test_interval_added_to_a_column
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query(<<~SQL)
        SELECT time, time + 1h AS later, time - 30s AS earlier
        FROM "#{database_name}"."#{table_name}"
        WHERE host = 'b'
      SQL

      row = rows_as_hashes(response).first
      assert_equal "2026-01-01 00:00:00.000000000", row["time"]
      assert_equal "2026-01-01 01:00:00.000000000", row["later"]
      assert_equal "2025-12-31 23:59:30.000000000", row["earlier"]
    end
  end

  def test_interval_added_to_a_no_argument_function_call
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query(<<~SQL)
        SELECT count(*) AS n
        FROM "#{database_name}"."#{table_name}"
        WHERE time < now() + 1h
      SQL

      assert_equal "5", rows_as_hashes(response).first["n"]
    end
  end

  # A bare `'...' + 1m` would have SQLite coerce the timestamp string to a number
  # and return 60000002026 without erroring. Rejecting the shape is deliberate.
  def test_unsupported_interval_expression_is_rejected
    error = assert_raises(Aws::TimestreamQuery::Errors::ValidationException) do
      query("SELECT '2026-01-01 00:00:00.000000000' + 1m AS later")
    end
    assert_match(/Unsupported interval expression/, error.message)
  end

  def test_interval_as_a_function_argument_still_works
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query(<<~SQL)
        SELECT count(*) AS n
        FROM "#{database_name}"."#{table_name}"
        WHERE time > ago(100000h) AND bin(time, 1h) IS NOT NULL
      SQL

      assert_equal "5", rows_as_hashes(response).first["n"]
    end
  end
end
