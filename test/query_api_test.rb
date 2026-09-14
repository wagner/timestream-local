# frozen_string_literal: true

require_relative "test_helper"

class QueryApiTest < TimestreamTest
  def seed(database_name, table_name, base_time = Time.now)
    records = 6.times.map do |index|
      {
        dimensions: [{ name: "region", value: index.even? ? "us-east-1" : "eu-west-1" }],
        measure_name: "metrics", measure_value_type: "MULTI",
        measure_values: [
          { name: "cpu", value: (10 * (index + 1)).to_s, type: "DOUBLE" },
          { name: "memory", value: (100 + index).to_s, type: "BIGINT" }
        ],
        time: millis(base_time - (index * 60))
      }
    end
    write_client.write_records(database_name: database_name, table_name: table_name, records: records)
  end

  def test_select_star_returns_timestream_column_order
    with_table do |database_name, table_name|
      seed(database_name, table_name, Time.now)

      response = query_client.query(query_string: %(SELECT * FROM "#{database_name}"."#{table_name}"))
      assert_equal %w[region measure_name time cpu memory], response.column_info.map(&:name)
      assert_equal %w[VARCHAR VARCHAR TIMESTAMP DOUBLE BIGINT],
                   response.column_info.map { |column| column.type.scalar_type }
      assert_equal 6, response.rows.size
    end
  end

  def test_unqualified_table_reference
    with_table do |database_name, table_name|
      seed(database_name, table_name, Time.now)

      response = query_client.query(query_string: "SELECT count(*) AS n FROM #{database_name}.#{table_name}")
      assert_equal "6", rows_as_hashes(response).first["n"]
    end
  end

  def test_ago_predicate_filters_by_time
    with_table do |database_name, table_name|
      # Offset by half a minute so no record sits on the 3m boundary. Records are
      # timestamped from this process's clock but ago() is evaluated on the
      # server's, and a record exactly on the cutoff flips on millisecond skew
      # between the two -- which is routine when the server is in a VM.
      seed(database_name, table_name, Time.now - 30)

      response = query_client.query(
        query_string: <<~SQL
          SELECT count(*) AS recent
          FROM "#{database_name}"."#{table_name}"
          WHERE time > ago(3m)
        SQL
      )
      # Records land at now-30s, now-90s ... now-330s, so three fall inside the
      # window and the nearest record either side of it is 30s clear.
      assert_equal "3", rows_as_hashes(response).first["recent"]
    end
  end

  def test_bin_aggregation
    with_table do |database_name, table_name|
      # Fixed base so all six records land in the same 10-minute bin; bins are
      # aligned to the epoch, so 19:09 back to 19:04 all fall in the 19:00 bucket.
      seed(database_name, table_name, Time.utc(2021, 12, 1, 19, 9, 0))

      response = query_client.query(
        query_string: <<~SQL
          SELECT bin(time, 10m) AS bucket, region, avg(cpu) AS avg_cpu
          FROM "#{database_name}"."#{table_name}"
          GROUP BY bin(time, 10m), region
          ORDER BY region
        SQL
      )

      rows = rows_as_hashes(response)
      assert_equal 2, rows.size
      assert_equal %w[eu-west-1 us-east-1], rows.map { |row| row["region"] }
      assert_equal "TIMESTAMP", response.column_info.first.type.scalar_type
      assert_match(/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:00\.000000000\z/, rows.first["bucket"])
      # eu-west-1 holds the odd indices: cpu 20, 40, 60.
      assert_equal "40.0", rows.first["avg_cpu"]
    end
  end

  def test_measure_value_column_is_addressable
    with_table do |database_name, table_name|
      write_client.write_records(
        database_name: database_name, table_name: table_name,
        records: [{
          dimensions: [{ name: "device_id", value: "sensor-1" }],
          measure_name: "temperature", measure_value: "35.5", measure_value_type: "DOUBLE",
          time: millis(Time.now)
        }]
      )

      response = query_client.query(
        query_string: <<~SQL
          SELECT device_id, measure_value::double AS temperature
          FROM "#{database_name}"."#{table_name}"
          WHERE measure_name = 'temperature' AND measure_value::double > 30
        SQL
      )
      assert_equal [{ "device_id" => "sensor-1", "temperature" => "35.5" }], rows_as_hashes(response)
    end
  end

  def test_null_measure_columns_are_reported_as_null_values
    with_table do |database_name, table_name|
      write_client.write_records(
        database_name: database_name, table_name: table_name,
        records: [
          {
            dimensions: [{ name: "device_id", value: "sensor-1" }], measure_name: "temperature",
            measure_value: "35.5", measure_value_type: "DOUBLE", time: millis(Time.now)
          },
          {
            dimensions: [{ name: "device_id", value: "sensor-1" }], measure_name: "moisture",
            measure_value: "21", measure_value_type: "BIGINT", time: millis(Time.now)
          }
        ]
      )

      response = query_client.query(
        query_string: %(SELECT measure_value::double FROM "#{database_name}"."#{table_name}" ) +
                      %(WHERE measure_name = 'moisture')
      )
      assert_equal true, response.rows.first.data.first.null_value
      assert_nil response.rows.first.data.first.scalar_value
    end
  end

  # Walks a paginated query the way a consumer has to: until the token runs
  # out, not until a page comes back empty.
  def pages_of(query, max_rows)
    pages = []
    token = nil
    loop do
      page = query_client.query(query_string: query, max_rows: max_rows, next_token: token)
      pages << page
      token = page.next_token
      break if token.nil? || pages.size > 20
    end
    pages
  end

  # The real service dispatches a paginated query before any row is ready, so
  # the first response arrives empty carrying a token. Verified against real
  # Timestream: six rows at four per page come back as 0, 4, 2.
  def test_pagination_with_max_rows
    with_table do |database_name, table_name|
      seed(database_name, table_name, Time.now)
      query = %(SELECT cpu FROM "#{database_name}"."#{table_name}" ORDER BY cpu)

      pages = pages_of(query, 4)

      assert_equal [0, 4, 2], pages.map { |page| page.rows.size }
      refute_nil pages.first.next_token
      assert_nil pages.last.next_token

      collected = pages.flat_map { |page| rows_as_hashes(page) }.map { |row| row["cpu"] }
      assert_equal %w[10.0 20.0 30.0 40.0 50.0 60.0], collected
    end
  end

  # A full page cannot be known to be the last, so it carries a token and the
  # query ends on an empty page. Only a short page is recognisably final.
  def test_an_even_division_ends_on_an_empty_page
    with_table do |database_name, table_name|
      seed(database_name, table_name, Time.now)
      query = %(SELECT cpu FROM "#{database_name}"."#{table_name}" ORDER BY cpu)

      pages = pages_of(query, 3)

      assert_equal [0, 3, 3, 0], pages.map { |page| page.rows.size }
      assert_equal 6, pages.sum { |page| page.rows.size }
    end
  end

  # A result that fits in one page is not streamed: it comes back whole, with
  # no dispatch page and no token. Same for a result of no rows at all.
  def test_a_result_that_fits_in_one_page_is_not_streamed
    with_table do |database_name, table_name|
      seed(database_name, table_name, Time.now)
      query = %(SELECT cpu FROM "#{database_name}"."#{table_name}")

      whole = query_client.query(query_string: query, max_rows: 100)
      assert_equal 6, whole.rows.size
      assert_nil whole.next_token

      empty = query_client.query(
        query_string: %(SELECT cpu FROM "#{database_name}"."#{table_name}" WHERE cpu > 1000), max_rows: 4
      )
      assert_equal 0, empty.rows.size
      assert_nil empty.next_token
    end
  end

  # One QueryId covers the whole query -- it is what CancelQuery takes and what
  # a log correlates on -- and a separate run of the same SQL gets its own.
  def test_a_query_id_spans_every_page_of_one_query
    with_table do |database_name, table_name|
      seed(database_name, table_name, Time.now)
      query = %(SELECT cpu FROM "#{database_name}"."#{table_name}" ORDER BY cpu)

      pages = pages_of(query, 4)
      assert_equal 3, pages.size
      assert_equal 1, pages.map(&:query_id).uniq.size

      refute_equal pages.first.query_id, pages_of(query, 4).first.query_id
    end
  end

  # 63 characters of uppercase base32, as the real service returns. Nothing
  # should parse one, but a consumer that stores it sees the real shape.
  def test_a_query_id_looks_like_the_real_service
    id = query_client.query(query_string: "SELECT 1").query_id

    assert_equal 63, id.length
    assert_match(/\A[A-Z2-7]{63}\z/, id)
  end

  def test_pagination_token_is_bound_to_the_query
    with_table do |database_name, table_name|
      seed(database_name, table_name, Time.now)
      token = query_client.query(
        query_string: %(SELECT cpu FROM "#{database_name}"."#{table_name}"), max_rows: 1
      ).next_token

      assert_raises(Aws::TimestreamQuery::Errors::ValidationException) do
        query_client.query(
          query_string: %(SELECT memory FROM "#{database_name}"."#{table_name}"), max_rows: 1, next_token: token
        )
      end
    end
  end

  def test_show_and_describe_statements
    with_table do |database_name, table_name|
      seed(database_name, table_name, Time.now)

      tables = rows_as_hashes(query_client.query(query_string: "SHOW TABLES FROM #{database_name}"))
      assert_equal [table_name], tables.map { |row| row["Table"] }

      measures = rows_as_hashes(query_client.query(query_string: "SHOW MEASURES FROM #{database_name}.#{table_name}"))
      assert_equal [{ "measure_name" => "metrics", "data_type" => "multi" }],
                   measures.map { |row| row.slice("measure_name", "data_type") }
      assert_equal [{ "data_type" => "varchar", "dimension_name" => "region" }],
                   JSON.parse(measures.first["dimensions"])

      described = rows_as_hashes(query_client.query(query_string: "DESCRIBE #{database_name}.#{table_name}"))
      assert_equal [%w[region varchar DIMENSION],
                    ["measure_name", "varchar", "MEASURE_NAME"],
                    %w[time timestamp TIMESTAMP],
                    %w[cpu double MULTI],
                    %w[memory bigint MULTI]],
                   described.map { |row| row.values_at("Column", "Type", "Timestream attribute type") }
    end
  end

  def test_querying_a_missing_table_fails
    error = assert_raises(Aws::TimestreamQuery::Errors::QueryExecutionException) do
      query_client.query(query_string: %(SELECT * FROM "nope"."nope"))
    end
    assert_match(/does not exist/, error.message)
  end

  def test_invalid_sql_is_reported_as_a_query_execution_error
    with_table do |database_name, table_name|
      assert_raises(Aws::TimestreamQuery::Errors::QueryExecutionException) do
        query_client.query(query_string: %(SELECT nonexistent_column FROM "#{database_name}"."#{table_name}"))
      end
    end
  end

  def test_string_literals_are_not_rewritten
    with_table do |database_name, table_name|
      write_client.write_records(
        database_name: database_name, table_name: table_name,
        records: [{
          dimensions: [{ name: "note", value: "measure_value::double" }],
          measure_name: "cpu", measure_value: "1.0", measure_value_type: "DOUBLE",
          time: millis(Time.now)
        }]
      )

      response = query_client.query(
        query_string: %(SELECT note FROM "#{database_name}"."#{table_name}" ) +
                      %(WHERE note = 'measure_value::double')
      )
      assert_equal [{ "note" => "measure_value::double" }], rows_as_hashes(response)
    end
  end
end
