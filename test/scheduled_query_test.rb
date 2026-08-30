# frozen_string_literal: true

require_relative "test_helper"

# Scheduled queries: register a query, trigger it by hand, and have its results
# land in another table with a completion callback.
class ScheduledQueryTest < TimestreamTest
  BASE_TIME = Time.utc(2026, 3, 1, 12, 0, 0)
  ROLE = "arn:aws:iam::000000000000:role/timestream-local"
  # A cron that never fires. Runs happen only through ExecuteScheduledQuery.
  NEVER = "cron(0 0 1 1 ? 2100)"

  # Events inside the [BASE_TIME, BASE_TIME + 1m) window, plus one outside it so
  # the @scheduled_runtime predicate has something to exclude.
  def seed(database_name, table_name)
    records = [["a", 0], ["a", 30], ["b", 10], ["a", 90]].map do |host, offset|
      {
        dimensions: [{ name: "host", value: host }],
        measure_name: "event", measure_value: "1", measure_value_type: "BIGINT",
        time: millis(BASE_TIME + offset)
      }
    end
    write_client.write_records(database_name: database_name, table_name: table_name, records: records)
  end

  def target_configuration(database_name, table_name)
    {
      timestream_configuration: {
        database_name: database_name, table_name: table_name,
        time_column: "binned",
        dimension_mappings: [{ name: "host", dimension_value_type: "VARCHAR" }],
        multi_measure_mappings: {
          target_multi_measure_name: "m",
          multi_measure_attribute_mappings: [
            { source_column: "events", measure_value_type: "BIGINT" }
          ]
        }
      }
    }
  end

  def rollup_sql(database_name, table_name)
    <<~SQL
      SELECT bin(time, 1m) AS binned, host, count(*) AS events
      FROM "#{database_name}"."#{table_name}"
      WHERE time >= @scheduled_runtime AND time < @scheduled_runtime + 1m
      GROUP BY bin(time, 1m), host
    SQL
  end

  def create_query(query_string:, target: nil, topic: "arn:aws:sns:us-east-1:000000000000:t")
    query_client.create_scheduled_query(
      name: unique("sq"),
      query_string: query_string,
      schedule_configuration: { schedule_expression: NEVER },
      notification_configuration: { sns_configuration: { topic_arn: topic } },
      target_configuration: target,
      scheduled_query_execution_role_arn: ROLE,
      error_report_configuration: { s3_configuration: { bucket_name: "errors" } }
    ).arn
  end

  # Runs are asynchronous, so results are waited for rather than assumed.
  def eventually(message, timeout: 15)
    deadline = Time.now + timeout
    loop do
      result = yield
      return result if result
      flunk("timed out waiting for #{message}") if Time.now > deadline

      sleep 0.05
    end
  end

  def target_rows(database_name, table_name)
    response = query_client.query(query_string: %(SELECT * FROM "#{database_name}"."#{table_name}"))
    rows_as_hashes(response)
  rescue Aws::TimestreamQuery::Errors::ServiceError
    []
  end

  # ----------------------------------------------------------------- lifecycle

  def test_create_describe_list_and_delete
    with_table do |database_name, table_name|
      arn = create_query(query_string: %(SELECT 1 AS n FROM "#{database_name}"."#{table_name}"))
      assert_match(%r{^arn:aws:timestream:.*:scheduled-query/}, arn)

      described = query_client.describe_scheduled_query(scheduled_query_arn: arn).scheduled_query
      assert_equal arn, described.arn
      assert_equal "ENABLED", described.state
      assert_equal NEVER, described.schedule_configuration.schedule_expression
      assert_equal ROLE, described.scheduled_query_execution_role_arn

      assert_includes query_client.list_scheduled_queries.scheduled_queries.map(&:arn), arn

      query_client.delete_scheduled_query(scheduled_query_arn: arn)
      assert_raises(Aws::TimestreamQuery::Errors::ResourceNotFoundException) do
        query_client.describe_scheduled_query(scheduled_query_arn: arn)
      end
    end
  end

  def test_executing_an_unknown_query_is_not_found
    assert_raises(Aws::TimestreamQuery::Errors::ResourceNotFoundException) do
      query_client.execute_scheduled_query(
        scheduled_query_arn: "arn:aws:timestream:us-east-1:000000000000:scheduled-query/nope-0000",
        invocation_time: BASE_TIME
      )
    end
  end

  # ------------------------------------------------------------------ the run

  def test_execute_writes_the_window_into_the_target_table
    with_table do |database_name, source|
      seed(database_name, source)
      target = unique("agg")
      write_client.create_table(database_name: database_name, table_name: target)

      arn = create_query(query_string: rollup_sql(database_name, source),
                         target: target_configuration(database_name, target))
      query_client.execute_scheduled_query(scheduled_query_arn: arn, invocation_time: BASE_TIME)

      rows = eventually("the rollup to land") do
        found = target_rows(database_name, target)
        found.size == 2 ? found.sort_by { |row| row["host"] } : nil
      end

      # The event at +90s is outside the window, so host a counts 2, not 3.
      assert_equal %w[a b], rows.map { |row| row["host"] }
      assert_equal %w[2 1], rows.map { |row| row["events"] }
      assert_equal ["m", "m"], rows.map { |row| row["measure_name"] }
      assert_equal "2026-03-01 12:00:00.000000000", rows.first["time"]
    end
  end

  def test_scheduled_runtime_binding_moves_the_window
    with_table do |database_name, source|
      seed(database_name, source)
      target = unique("agg")
      write_client.create_table(database_name: database_name, table_name: target)

      arn = create_query(query_string: rollup_sql(database_name, source),
                         target: target_configuration(database_name, target))
      # One minute later: only the event at +90s falls inside.
      query_client.execute_scheduled_query(scheduled_query_arn: arn, invocation_time: BASE_TIME + 60)

      rows = eventually("the later window to land") do
        found = target_rows(database_name, target)
        found.empty? ? nil : found
      end

      assert_equal 1, rows.size
      assert_equal "a", rows.first["host"]
      assert_equal "1", rows.first["events"]
      assert_equal "2026-03-01 12:01:00.000000000", rows.first["time"]
    end
  end

  def test_describe_reports_the_last_run
    with_table do |database_name, source|
      seed(database_name, source)
      target = unique("agg")
      write_client.create_table(database_name: database_name, table_name: target)

      arn = create_query(query_string: rollup_sql(database_name, source),
                         target: target_configuration(database_name, target))
      query_client.execute_scheduled_query(scheduled_query_arn: arn, invocation_time: BASE_TIME)

      summary = eventually("the run summary") do
        described = query_client.describe_scheduled_query(scheduled_query_arn: arn).scheduled_query
        described.last_run_summary
      end

      assert_equal "AUTO_TRIGGER_SUCCESS", summary.run_status
      assert_equal BASE_TIME, summary.invocation_time
      assert_equal 2, summary.execution_stats.records_ingested
      assert_equal 2, summary.execution_stats.query_result_rows
    end
  end

  def test_a_failing_query_records_a_failed_run
    with_table do |database_name, table_name|
      arn = create_query(query_string: %(SELECT * FROM "#{database_name}"."does_not_exist_#{table_name}"))
      query_client.execute_scheduled_query(scheduled_query_arn: arn, invocation_time: BASE_TIME)

      summary = eventually("the failure summary") do
        query_client.describe_scheduled_query(scheduled_query_arn: arn).scheduled_query.last_run_summary
      end

      assert_equal "AUTO_TRIGGER_FAILURE", summary.run_status
      assert_match(/does not exist/, summary.failure_reason)
    end
  end

  # -------------------------------------------------------------- callbacks

  # Built without HTTP so the envelope is asserted in every run mode, including
  # against a container that cannot reach a receiver on this host.
  def scheduled_query_api
    store = TimestreamLocal::Store.new(path: ":memory:")
    TimestreamLocal::ScheduledQueryApi.new(store, TimestreamLocal::WriteApi.new(store),
                                           TimestreamLocal::QueryApi.new(store))
  end

  def test_notification_envelope_matches_the_sns_shape
    arn = "arn:aws:timestream:us-east-1:000000000000:scheduled-query/x-1"
    stats = { "executionTimeInMillis" => 3, "dataWrites" => 2, "bytesMetered" => 0,
              "recordsIngested" => 2, "queryResultRows" => 2 }
    payload = scheduled_query_api.notification_payload(
      arn, "MANUAL_TRIGGER_SUCCESS",
      { "invocationEpochSecond" => 1_772_366_400, "triggerTimeMillis" => 1_772_366_401_000,
        "runStatus" => "AUTO_TRIGGER_SUCCESS", "executionStats" => stats }
    )

    # Dispatch keys on Type; anything else is rejected by the receiver.
    assert_equal "Notification", payload["Type"]
    assert_equal arn, payload.dig("MessageAttributes", "queryArn", "Value")
    # Message is a JSON string, as SNS delivers it -- not a nested object.
    assert_kind_of String, payload["Message"]

    message = JSON.parse(payload["Message"])
    assert_equal "MANUAL_TRIGGER_SUCCESS", message["type"]
    assert_equal arn, message["arn"]
    summary = message["scheduledQueryRunSummary"]
    assert_equal 1_772_366_400, summary["invocationEpochSecond"]
    assert_equal "AUTO_TRIGGER_SUCCESS", summary["runStatus"]
    assert_equal stats, summary["executionStats"]
  end

  def test_failure_notification_carries_no_run_summary
    payload = scheduled_query_api.notification_payload("arn:x", "MANUAL_TRIGGER_FAILURE", nil)
    message = JSON.parse(payload["Message"])

    assert_equal "MANUAL_TRIGGER_FAILURE", message["type"]
    refute message.key?("scheduledQueryRunSummary")
  end

  # Records callbacks so delivery can be asserted, not just the payload.
  def with_receiver
    require "puma"

    received = Queue.new
    app = lambda do |env|
      received << { body: env["rack.input"].read, content_type: env["CONTENT_TYPE"], path: env["PATH_INFO"] }
      [201, { "content-type" => "application/json" }, ["{}"]]
    end
    server = Puma::Server.new(app)
    port = server.add_tcp_listener("127.0.0.1", 0).addr[1]
    server.run
    yield "http://127.0.0.1:#{port}/notifications", received
  ensure
    begin
      server&.stop(true)
    rescue StandardError
      nil
    end
  end

  def test_a_successful_run_posts_the_callback
    # The receiver listens on this host; a server running elsewhere cannot reach it.
    skip "callback delivery is asserted in-process" if ENV["TIMESTREAM_LOCAL_ENDPOINT"]

    with_table do |database_name, source|
      seed(database_name, source)
      target = unique("agg")
      write_client.create_table(database_name: database_name, table_name: target)

      with_receiver do |url, received|
        # An http(s) TopicArn overrides the default receiver for this query.
        arn = create_query(query_string: rollup_sql(database_name, source),
                           target: target_configuration(database_name, target), topic: url)
        query_client.execute_scheduled_query(scheduled_query_arn: arn, invocation_time: BASE_TIME)

        callback = eventually("the completion callback") { received.pop unless received.empty? }
        assert_equal "/notifications", callback[:path]
        assert_match(%r{application/json}, callback[:content_type])

        message = JSON.parse(JSON.parse(callback[:body])["Message"])
        assert_equal "MANUAL_TRIGGER_SUCCESS", message["type"]
        assert_equal arn, message["arn"]
        # Must echo the InvocationTime that was passed in: a receiver matching on
        # this value discards anything else as a stale callback.
        assert_equal BASE_TIME.to_i, message.dig("scheduledQueryRunSummary", "invocationEpochSecond")
        assert_equal 2, message.dig("scheduledQueryRunSummary", "executionStats", "recordsIngested")
      end
    end
  end

  def test_a_failed_run_posts_a_failure_callback
    skip "callback delivery is asserted in-process" if ENV["TIMESTREAM_LOCAL_ENDPOINT"]

    with_table do |database_name, table_name|
      with_receiver do |url, received|
        arn = create_query(query_string: %(SELECT * FROM "#{database_name}"."missing_#{table_name}"), topic: url)
        query_client.execute_scheduled_query(scheduled_query_arn: arn, invocation_time: BASE_TIME)

        callback = eventually("the failure callback") { received.pop unless received.empty? }
        message = JSON.parse(JSON.parse(callback[:body])["Message"])
        assert_equal "MANUAL_TRIGGER_FAILURE", message["type"]
        assert_equal arn, message["arn"]
      end
    end
  end

  # A query with no TargetConfiguration is legal; it simply writes nowhere.
  def test_execute_without_a_target_is_a_no_op
    with_table do |database_name, source|
      seed(database_name, source)
      arn = create_query(query_string: rollup_sql(database_name, source))
      query_client.execute_scheduled_query(scheduled_query_arn: arn, invocation_time: BASE_TIME)

      summary = eventually("the run summary") do
        query_client.describe_scheduled_query(scheduled_query_arn: arn).scheduled_query.last_run_summary
      end
      assert_equal "AUTO_TRIGGER_SUCCESS", summary.run_status
      assert_equal 0, summary.execution_stats.records_ingested
    end
  end
end
