# frozen_string_literal: true

require_relative "test_helper"

# The browser at GET /. It reads through the same QueryApi clients use, so a
# column type or datum shape that is wrong here is wrong on the wire too.
class WebUiTest < TimestreamTest
  AT = Time.utc(2026, 8, 30, 12, 0, 0)

  def get(path = "/", **params)
    query = params.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }.join("&")
    uri = URI("#{endpoint}#{path}#{query.empty? ? '' : "?#{query}"}")
    Net::HTTP.get_response(uri)
  end

  # The second record omits `note`, so that column is genuinely NULL for it --
  # a real absent measure rather than a NULL literal.
  def seed(database_name, table_name)
    records = [
      { values: [{ name: "cpu", value: "10.5", type: "DOUBLE" },
                 { name: "note", value: %(needs "escaping" & <b>care</b>), type: "VARCHAR" }],
        offset: 0 },
      { values: [{ name: "cpu", value: "20.5", type: "DOUBLE" }], offset: 60 }
    ].map do |row|
      {
        dimensions: [{ name: "host", value: "web-1" }],
        measure_name: "metrics", measure_value_type: "MULTI",
        measure_values: row[:values], time: millis(AT + row[:offset])
      }
    end
    write_client.write_records(database_name: database_name, table_name: table_name, records: records)
  end

  def test_index_is_html
    response = get
    assert_equal "200", response.code
    assert_match(%r{text/html}, response["content-type"])
    assert_match(/timestream-local/, response.body)
  end

  def test_lists_databases_and_the_tables_of_the_selected_one
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      body = get("/", db: database_name).body
      assert_includes body, database_name
      assert_includes body, table_name
    end
  end

  def test_runs_a_query_and_renders_values_with_their_types
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      body = get("/", db: database_name,
                      q: %(SELECT host, cpu, time FROM "#{database_name}"."#{table_name}")).body

      assert_includes body, "web-1"
      assert_includes body, "10.5"
      assert_includes body, "2026-08-30 12:00:00.000000000"
      # Column types come from the same resolution the wire format uses.
      assert_includes body, "TIMESTAMP"
      assert_includes body, "DOUBLE"
    end
  end

  # Values are written by clients, so they reach the page as untrusted text.
  def test_escapes_html_in_values
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      body = get("/", db: database_name,
                      q: %(SELECT note FROM "#{database_name}"."#{table_name}")).body

      refute_includes body, "<b>care</b>"
      assert_includes body, "&lt;b&gt;care&lt;/b&gt;"
      assert_includes body, "&quot;escaping&quot;"
    end
  end

  def test_a_null_is_shown_as_null_rather_than_blank
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      body = get("/", db: database_name,
                      q: %(SELECT time, note FROM "#{database_name}"."#{table_name}" ORDER BY time)).body
      assert_match(/class="null">NULL/, body)
    end
  end

  def test_a_time_series_column_shows_its_element_type_and_points
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      body = get("/", db: database_name, q: <<~SQL).body
        SELECT create_time_series(time, cpu) AS series
        FROM "#{database_name}"."#{table_name}" GROUP BY host
      SQL

      assert_includes body, "TIMESERIES&lt;DOUBLE&gt;"
      assert_includes body, "2 points"
    end
  end

  # A bad query is a normal thing to type; it must not 500.
  def test_a_failing_query_renders_the_error
    with_table do |database_name, _table_name|
      response = get("/", db: database_name, q: %(SELECT * FROM "#{database_name}"."nope"))

      assert_equal "200", response.code
      assert_includes response.body, "QueryExecutionException"
      assert_includes response.body, "does not exist"
    end
  end

  # A cron that never fires; runs happen only through ExecuteScheduledQuery.
  NEVER = "cron(0 0 1 1 ? 2100)"

  def create_scheduled_query(database_name, table_name, name)
    query_client.create_scheduled_query(
      name: name,
      query_string: %(SELECT host, cpu, time FROM "#{database_name}"."#{table_name}"),
      schedule_configuration: { schedule_expression: NEVER },
      notification_configuration: { sns_configuration: { topic_arn: "arn:aws:sns:us-east-1:000000000000:t" } },
      target_configuration: {
        timestream_configuration: {
          database_name: database_name, table_name: table_name, time_column: "time",
          dimension_mappings: [{ name: "host", dimension_value_type: "VARCHAR" }],
          multi_measure_mappings: {
            target_multi_measure_name: "m",
            multi_measure_attribute_mappings: [{ source_column: "cpu", measure_value_type: "DOUBLE" }]
          }
        }
      },
      scheduled_query_execution_role_arn: "arn:aws:iam::000000000000:role/timestream-local",
      error_report_configuration: { s3_configuration: { bucket_name: "errors" } }
    ).arn
  end

  def test_lists_scheduled_queries_and_shows_one
    with_table do |database_name, table_name|
      name = unique("sq")
      arn = create_scheduled_query(database_name, table_name, name)

      assert_includes get("/").body, name

      body = get("/", sq: arn).body
      assert_includes body, CGI.escapeHTML(NEVER)
      assert_includes body, "#{database_name}.#{table_name}"
      # Never triggered, so there is no run to report yet.
      assert_includes body, "never run"
      assert_includes body, CGI.escapeHTML(%(FROM "#{database_name}"."#{table_name}"))
    ensure
      query_client.delete_scheduled_query(scheduled_query_arn: arn) if arn
    end
  end

  def test_the_last_run_of_a_scheduled_query_is_shown
    with_table do |database_name, table_name|
      seed(database_name, table_name)
      arn = create_scheduled_query(database_name, table_name, unique("sq"))
      query_client.execute_scheduled_query(scheduled_query_arn: arn, invocation_time: AT)

      # The run is asynchronous, so the page is polled rather than assumed.
      body = nil
      deadline = Time.now + 15
      loop do
        body = get("/", sq: arn).body
        break if body.include?("AUTO_TRIGGER_SUCCESS")
        flunk("timed out waiting for the run to be reported") if Time.now > deadline

        sleep 0.05
      end

      assert_includes body, "Last run"
      assert_includes body, "2026-08-30 12:00:00 UTC"
      assert_includes body, ">2<" # two result rows, both ingested
    ensure
      query_client.delete_scheduled_query(scheduled_query_arn: arn) if arn
    end
  end

  # A stale link is a normal thing to follow; it must not 500.
  def test_an_unknown_scheduled_query_renders_the_error
    response = get("/", sq: "arn:aws:timestream:us-east-1:000000000000:scheduled-query/nope-0000")

    assert_equal "200", response.code
    assert_includes response.body, "ResourceNotFoundException"
  end

  def test_the_rpc_surface_is_unaffected
    # The browser is on GET; POST / is still the API.
    assert write_client.list_databases.databases
    assert_equal "200", get("/health").code
  end

  def test_the_ui_can_be_turned_off
    skip "toggling the UI needs the server in this process" if ENV["TIMESTREAM_LOCAL_ENDPOINT"]

    TimestreamLocal::WebUi.enabled = false
    # With the browser off, GET / is just an unsupported method on the RPC path.
    assert_equal "405", get("/").code
  ensure
    TimestreamLocal::WebUi.enabled = true
  end
end
