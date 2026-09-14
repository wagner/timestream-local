# frozen_string_literal: true

require_relative "test_helper"

# The metering figures are approximations -- there is no scan accounting in
# SQLite to take them from -- so what is asserted here is the shape a consumer
# depends on: they move with the data, a query that reads a table keeps the
# floor it is charged, and a statement that reads no table is free.
#
# The rules come from real Timestream, verified against
# query.timestream.us-east-1.amazonaws.com: `SELECT 1` and DESCRIBE report 0/0,
# a scan of any size meters at least 10,000,000 bytes, and both figures plateau
# once the query has finished, so paging does not add to them.
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

  # The floor is decimal MB. A consumer that hard-codes 10 * 1024 * 1024 is
  # wrong against real Timestream, and pinning the value here is what stops
  # this emulator from confirming that mistake.
  def test_the_floor_is_ten_million_bytes
    assert_equal 10_000_000, FLOOR
  end

  # A cheap query is not free in the real service, and a consumer costing one
  # out has to see that.
  def test_the_metered_figure_keeps_its_floor
    with_table do |database_name, table_name|
      seed(database_name, table_name, 1)

      metered = status(%(SELECT * FROM "#{database_name}"."#{table_name}"))
      assert_operator metered.cumulative_bytes_scanned, :<, FLOOR
      assert_equal FLOOR, metered.cumulative_bytes_metered

      # A predicate that matched nothing still read the table, so it still
      # meters the floor -- real Timestream reports 0 scanned and the full
      # 10,000,000 metered for exactly this case. The split is on whether a
      # table was read, not on whether the scan came to zero.
      empty = status(%(SELECT * FROM "#{database_name}"."#{table_name}" WHERE host = 'nobody'))
      assert_equal 0, empty.cumulative_bytes_scanned
      assert_equal FLOOR, empty.cumulative_bytes_metered
    end
  end

  # Both figures are cumulative for the query and plateau once it has finished,
  # so walking the rest of a completed result set must not add to either.
  def test_paging_a_finished_query_adds_to_neither_figure
    with_table do |database_name, table_name|
      seed(database_name, table_name, 5)
      sql = %(SELECT * FROM "#{database_name}"."#{table_name}")

      whole = status(sql)
      pages = []
      token = nil
      loop do
        page = query_client.query(query_string: sql, max_rows: 2, next_token: token)
        pages << page
        token = page.next_token
        break if token.nil?
      end

      # A dispatch page, two full pages and a short one: see the pagination
      # tests in query_api_test.rb for why the first page is empty.
      assert_equal 4, pages.size
      assert_equal 5, pages.sum { |page| page.rows.size }
      pages.each do |page|
        assert_equal whole.cumulative_bytes_scanned, page.query_status.cumulative_bytes_scanned
        assert_equal whole.cumulative_bytes_metered, page.query_status.cumulative_bytes_metered
      end
    end
  end

  # Real Timestream charges nothing for a statement that reads no table, and
  # applies no floor to it. Metering one is what made a local budget drain on
  # calls that cost nothing in the account they were modelled on.
  def test_the_catalog_is_free
    with_table do |database_name, table_name|
      seed(database_name, table_name, 1)

      [%(DESCRIBE "#{database_name}"."#{table_name}"),
       %(SHOW TABLES FROM "#{database_name}"),
       %(SHOW MEASURES FROM "#{database_name}"."#{table_name}"),
       "SHOW DATABASES"].each do |sql|
        metadata = status(sql)
        assert_equal 0, metadata.cumulative_bytes_scanned, sql
        assert_equal 0, metadata.cumulative_bytes_metered, sql
      end
    end
  end

  # The sharpest case: an expression naming no table scans nothing, so there is
  # nothing to meter and no floor to apply.
  def test_a_query_over_no_table_is_free
    trivial = status("SELECT 1")

    assert_equal 0, trivial.cumulative_bytes_scanned
    assert_equal 0, trivial.cumulative_bytes_metered
  end
end
