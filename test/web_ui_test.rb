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
