# frozen_string_literal: true

require "stringio"

require_relative "test_helper"

# Verbose mode. Off by default; when on, one line per request and one for the
# SQL that actually ran.
class LogTest < TimestreamTest
  def capture
    previous = TimestreamLocal::Log.io
    io = StringIO.new
    TimestreamLocal::Log.io = io
    TimestreamLocal::Log.enabled = true
    yield
    io.string
  ensure
    TimestreamLocal::Log.enabled = false
    TimestreamLocal::Log.io = previous
  end

  def test_nothing_is_written_when_verbose_is_off
    io = StringIO.new
    TimestreamLocal::Log.io = io
    TimestreamLocal::Log.enabled = false
    TimestreamLocal::Log.event("Query", sql: "SELECT 1")

    assert_empty io.string
  ensure
    TimestreamLocal::Log.io = $stdout
  end

  def test_an_event_is_one_line_of_fields
    output = capture { TimestreamLocal::Log.event("Query", database: "db", rows: 3, token: nil) }

    assert_equal 1, output.lines.size
    assert_match(/\[timestream-local\] \d\d:\d\d:\d\d\.\d\d\d Query /, output)
    assert_includes output, "database=db"
    assert_includes output, "rows=3"
    # Fields that are nil say nothing rather than saying nil.
    refute_includes output, "token"
  end

  # A value with spaces in it is quoted, so a field cannot be read as two.
  def test_multi_line_values_are_folded_and_quoted
    output = capture { TimestreamLocal::Log.event("sqlite", sql: "SELECT 1\nFROM t") }

    assert_equal 1, output.lines.size
    assert_includes output, %(sql="SELECT 1 FROM t")
  end

  def test_a_request_logs_the_operation_and_the_sql_that_ran
    skip "verbose output is only visible in-process" if ENV["TIMESTREAM_LOCAL_ENDPOINT"]

    with_table do |database_name, table_name|
      output = capture do
        query_client.query(query_string: %(SELECT * FROM "#{database_name}"."#{table_name}"))
      end

      assert_match(/ Query sql=".*#{table_name}.*" rows=0/, output)
      # The rewritten statement is what says why a query came back empty.
      assert_match(/ sqlite sql=".*#{table_name}.*"/, output)
    end
  end

  def test_a_failing_request_logs_the_error
    skip "verbose output is only visible in-process" if ENV["TIMESTREAM_LOCAL_ENDPOINT"]

    output = capture do
      assert_raises(Aws::TimestreamQuery::Errors::ServiceError) do
        query_client.query(query_string: %(SELECT * FROM "nope"."nope"))
      end
    end

    assert_includes output, "error=QueryExecutionException"
  end
end
