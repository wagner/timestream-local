# frozen_string_literal: true

require_relative "test_helper"

# The metering figures are approximations -- there is no scan accounting in
# SQLite to take them from -- so what is asserted here is the shape a consumer
# depends on: they are non-zero, they move with the data, and the metered figure
# keeps the floor a real query is charged.
class MeteringTest < TimestreamTest
  AT = Time.utc(2026, 8, 30, 12, 0, 0)
  FLOOR = TimestreamLocal::Metering::MINIMUM_METERED_BYTES

  # `from` moves the batch past an earlier one: same dimensions at the same time
  # is a duplicate, and a rejected write is not what these tests are measuring.
  def seed(database_name, table_name, count, from: 0)
    records = count.times.map do |offset|
      index = from + offset
      {
        dimensions: [{ name: "host", value: "web-#{index}" }],
        measure_name: "metrics", measure_value_type: "MULTI",
        measure_values: [{ name: "cpu", value: (index + 1).to_s, type: "DOUBLE" },
                         { name: "note", value: "a" * 100, type: "VARCHAR" }],
        time: millis(AT + index)
      }
    end
    write_client.write_records(database_name: database_name, table_name: table_name, records: records)
  end

  def status(sql, **options)
    query_client.query(query_string: sql, **options).query_status
  end

  def test_a_query_reports_the_bytes_it_scanned
    with_table do |database_name, table_name|
      seed(database_name, table_name, 3)

      wide = status(%(SELECT * FROM "#{database_name}"."#{table_name}"))
      narrow = status(%(SELECT host FROM "#{database_name}"."#{table_name}"))

      assert_operator wide.cumulative_bytes_scanned, :>, 0
      # Fewer columns is less data read, and the figure has to move with it.
      assert_operator narrow.cumulative_bytes_scanned, :<, wide.cumulative_bytes_scanned
      assert_in_delta 100.0, wide.progress_percentage
    end
  end

  def test_more_rows_scan_more_bytes
    with_table do |database_name, table_name|
      seed(database_name, table_name, 2)
      two = status(%(SELECT * FROM "#{database_name}"."#{table_name}")).cumulative_bytes_scanned

      seed(database_name, table_name, 4, from: 2)
      six = status(%(SELECT * FROM "#{database_name}"."#{table_name}")).cumulative_bytes_scanned

      assert_operator six, :>, two
    end
  end

  # A cheap query is not free in the real service, and a consumer costing one
  # out has to see that.
  def test_the_metered_figure_keeps_its_floor
    with_table do |database_name, table_name|
      seed(database_name, table_name, 1)

      metered = status(%(SELECT * FROM "#{database_name}"."#{table_name}"))
      assert_operator metered.cumulative_bytes_scanned, :<, FLOOR
      assert_equal FLOOR, metered.cumulative_bytes_metered

      # Matching nothing still meters the floor; scanning nothing is still zero.
      empty = status(%(SELECT * FROM "#{database_name}"."#{table_name}" WHERE host = 'nobody'))
      assert_equal 0, empty.cumulative_bytes_scanned
      assert_equal FLOOR, empty.cumulative_bytes_metered
    end
  end

  # Paging does not change what the query read, so each page reports the whole.
  def test_a_page_reports_what_the_whole_query_scanned
    with_table do |database_name, table_name|
      seed(database_name, table_name, 5)
      sql = %(SELECT * FROM "#{database_name}"."#{table_name}")

      whole = status(sql).cumulative_bytes_scanned
      first_page = query_client.query(query_string: sql, max_rows: 2)

      assert_equal 2, first_page.rows.size
      assert first_page.next_token
      assert_equal whole, first_page.query_status.cumulative_bytes_scanned
    end
  end

  def test_the_catalog_is_cheap_but_not_free
    with_table do |database_name, table_name|
      seed(database_name, table_name, 1)

      described = status(%(DESCRIBE "#{database_name}"."#{table_name}"))
      assert_operator described.cumulative_bytes_scanned, :>, 0
      assert_operator described.cumulative_bytes_scanned, :<, FLOOR
    end
  end
end
