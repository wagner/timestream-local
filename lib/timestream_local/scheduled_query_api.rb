# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module TimestreamLocal
  # Scheduled queries, reduced to the part that is actually mechanical: run a
  # query, write its results into another table, then say so.
  #
  # There is no scheduler. `ScheduleExpression` is stored and echoed back but
  # never interpreted -- runs happen only when `ExecuteScheduledQuery` asks for
  # one. That matches how the feature is driven here (every query is registered
  # with a cron expression that never fires) and means nothing happens behind
  # the caller's back.
  #
  # Execution is asynchronous, as it is in the real service: ExecuteScheduledQuery
  # returns immediately and the run -- including the completion callback -- happens
  # on another thread. That ordering is deliberate. A caller that persists its
  # state before the API call and treats the callback as the completion signal
  # would deadlock against a synchronous implementation if it were single
  # threaded, because the callback would arrive before the call it belongs to had
  # returned.
  class ScheduledQueryApi
    RUNTIME_PARAMETER = "@scheduled_runtime"
    MAX_RECORDS_PER_REQUEST = 100
    SUCCESS = "MANUAL_TRIGGER_SUCCESS"
    FAILURE = "MANUAL_TRIGGER_FAILURE"

    class << self
      # Where completion callbacks are posted when a query's SnsConfiguration
      # does not name an http(s) URL of its own.
      attr_writer :notification_url

      # An unset variable arrives as "" when compose interpolates a missing value,
      # which is the same as having no receiver rather than a receiver at "".
      def notification_url
        return @notification_url if defined?(@notification_url)

        value = ENV.fetch("TIMESTREAM_LOCAL_NOTIFICATION_URL", nil)
        value.nil? || value.empty? ? nil : value
      end
    end

    def initialize(store, write_api, query_api)
      @store = store
      @write_api = write_api
      @query_api = query_api
    end

    def create_scheduled_query(params)
      query_string = params["QueryString"]
      raise ValidationException, "QueryString is required" if blank?(query_string)
      raise ValidationException, "ScheduleConfiguration is required" if params["ScheduleConfiguration"].nil?
      raise ValidationException, "NotificationConfiguration is required" if params["NotificationConfiguration"].nil?

      validate_target!(params["TargetConfiguration"])

      arn = @store.create_scheduled_query(
        params["Name"],
        query_string: query_string,
        schedule: params["ScheduleConfiguration"],
        notification: params["NotificationConfiguration"],
        target: params["TargetConfiguration"],
        error_report: params["ErrorReportConfiguration"],
        execution_role_arn: params["ScheduledQueryExecutionRoleArn"],
        kms_key_id: params["KmsKeyId"]
      )
      { "Arn" => arn }
    end

    def delete_scheduled_query(params)
      @store.delete_scheduled_query(require_arn(params))
      {}
    end

    def describe_scheduled_query(params)
      { "ScheduledQuery" => description(@store.scheduled_query(require_arn(params))) }
    end

    def list_scheduled_queries(_params)
      queries = @store.list_scheduled_queries.map do |record|
        {
          "Arn" => record["arn"], "Name" => record["name"], "State" => record["state"],
          "CreationTime" => record["created_at"],
          "PreviousInvocationTime" => record.dig("last_run", "invocation_time"),
          "ErrorReportConfiguration" => presence(record["error_report"]),
          "TargetDestination" => target_destination(record),
          "LastRunStatus" => record.dig("last_run", "run_status")
        }.compact
      end
      { "ScheduledQueries" => queries }
    end

    def execute_scheduled_query(params)
      record = @store.scheduled_query(require_arn(params))
      invocation_time = parse_invocation_time(params["InvocationTime"])

      start(record, invocation_time)
      {}
    end

    # Builds the completion callback without sending it. Exposed so its shape can
    # be asserted without standing up an HTTP receiver.
    def notification_payload(arn, type, summary)
      message = { "type" => type, "arn" => arn }
      message["scheduledQueryRunSummary"] = summary if summary

      {
        "Type" => "Notification",
        "MessageAttributes" => { "queryArn" => { "Value" => arn } },
        # SNS delivers Message as a JSON string, not a nested object.
        "Message" => JSON.dump(message)
      }
    end

    private

    def start(record, invocation_time)
      Thread.new { run(record, invocation_time) }
    end

    def run(record, invocation_time)
      arn = record["arn"]
      started = now_monotonic
      Log.event("scheduled_query.start", name: record["name"], arn: arn, invocation_time: invocation_time)
      begin
        columns, rows, _types, scanned = execute_query(record, invocation_time)
        ingested, written = write_results(record, columns, rows)
        summary = run_summary(invocation_time, started, "AUTO_TRIGGER_SUCCESS",
                              ingested: ingested, result_rows: rows.size,
                              scanned: scanned, written: written)
        @store.record_scheduled_query_run(arn, summary)
        Log.event("scheduled_query.run", name: record["name"], status: "AUTO_TRIGGER_SUCCESS",
                                         rows: rows.size, ingested: ingested, bytes: written,
                                         ms: summary.dig("executionStats", "executionTimeInMillis"))
        notify(record, arn, SUCCESS, summary)
      rescue StandardError => e
        warn("[timestream-local] scheduled query #{arn} failed: #{e.class}: #{e.message}")
        Log.event("scheduled_query.run", name: record["name"], status: "AUTO_TRIGGER_FAILURE",
                                         error: e.class, message: e.message)
        summary = run_summary(invocation_time, started, "AUTO_TRIGGER_FAILURE",
                              ingested: 0, result_rows: 0).merge("failureReason" => e.message)
        @store.record_scheduled_query_run(arn, summary)
        # The failure callback carries no run summary, matching the real service.
        notify(record, arn, FAILURE, nil)
      end
    end

    # @scheduled_runtime is bound rather than interpolated. Substituting it as a
    # literal first would defeat the rewriter, which needs to see the parameter
    # to turn `@scheduled_runtime + 1m` into date_add_ns() -- a quoted timestamp
    # on the left of `+` is rejected as an unsupported interval expression.
    def execute_query(record, invocation_time)
      query_string = record["query_string"]
      binds = query_string.include?(RUNTIME_PARAMETER) ? [Types.ns_to_iso(invocation_time * 1_000_000_000)] : []
      @query_api.execute_statement(query_string, binds)
    end

    # Returns what was ingested, as a count and as approximate bytes: the run
    # summary reports both, and they are not the same field.
    def write_results(record, columns, rows)
      target = record.dig("target", "TimestreamConfiguration")
      return [0, 0] if target.nil?

      index = columns.each_with_index.to_h
      records = rows.filter_map { |row| build_record(target, index, row, columns) }
      return [0, 0] if records.empty?

      records.each_slice(MAX_RECORDS_PER_REQUEST) do |batch|
        @write_api.write_records(
          "DatabaseName" => target["DatabaseName"], "TableName" => target["TableName"], "Records" => batch
        )
      end
      [records.size, Metering.written_bytes(records)]
    end

    # Result columns not named in the mappings are dropped, as they are by the
    # real service.
    def build_record(target, index, row, columns)
      time = column_value(row, index, target["TimeColumn"])
      return nil if time.nil?

      dimensions = Array(target["DimensionMappings"]).map do |mapping|
        value = column_value(row, index, mapping["Name"])
        return nil if value.nil?

        { "Name" => mapping["Name"], "Value" => Types.format_scalar(value, "VARCHAR") }
      end

      measure_values = multi_measure_values(target, index, row)
      return nil if measure_values.empty?

      {
        "Time" => Types.iso_to_ns(time).to_s, "TimeUnit" => "NANOSECONDS",
        "Dimensions" => dimensions,
        "MeasureName" => measure_name(target, index, row, columns),
        "MeasureValueType" => "MULTI",
        "MeasureValues" => measure_values
      }
    end

    def multi_measure_values(target, index, row)
      mappings = target.dig("MultiMeasureMappings", "MultiMeasureAttributeMappings")
      Array(mappings).filter_map do |mapping|
        value = column_value(row, index, mapping["SourceColumn"])
        next nil if value.nil?

        {
          "Name" => mapping["TargetMultiMeasureAttributeName"] || mapping["SourceColumn"],
          "Value" => Types.format_scalar(value, mapping["MeasureValueType"]),
          "Type" => mapping["MeasureValueType"]
        }
      end
    end

    def measure_name(target, index, row, columns)
      if target["MeasureNameColumn"] && columns.include?(target["MeasureNameColumn"])
        return column_value(row, index, target["MeasureNameColumn"]).to_s
      end

      target.dig("MultiMeasureMappings", "TargetMultiMeasureName") || "measure_value"
    end

    def column_value(row, index, name)
      position = index[name]
      position && row[position]
    end

    def validate_target!(target)
      configuration = target&.dig("TimestreamConfiguration")
      return if configuration.nil?

      if configuration["MixedMeasureMappings"] && configuration["MultiMeasureMappings"].nil?
        raise ValidationException,
              "MixedMeasureMappings is not supported by timestream-local; use MultiMeasureMappings."
      end

      %w[DatabaseName TableName TimeColumn].each do |field|
        raise ValidationException, "TimestreamConfiguration.#{field} is required" if blank?(configuration[field])
      end
    end

    # `scanned` is nil for a run that never got as far as reading anything, and
    # nothing read meters nothing -- the floor applies to queries that ran.
    def run_summary(invocation_time, started, status, ingested:, result_rows:, scanned: nil, written: 0)
      elapsed = ((now_monotonic - started) * 1000).round
      {
        "invocation_time" => invocation_time,
        "run_status" => status,
        "invocationEpochSecond" => invocation_time,
        "triggerTimeMillis" => (Time.now.to_f * 1000).round,
        "runStatus" => status,
        "executionStats" => {
          "executionTimeInMillis" => elapsed,
          "dataWrites" => written,
          "bytesMetered" => scanned.nil? ? 0 : Metering.metered_bytes(scanned),
          "recordsIngested" => ingested,
          "queryResultRows" => result_rows
        }
      }
    end

    def notify(record, arn, type, summary)
      url = notification_url(record)
      return if url.nil? || url.empty?

      payload = notification_payload(arn, type, summary && summary.slice(
        "invocationEpochSecond", "triggerTimeMillis", "runStatus", "executionStats"
      ))
      deliver(url, payload)
    end

    # A TopicArn that is really an http(s) URL overrides the default, so a single
    # server can route individual queries at different receivers.
    def notification_url(record)
      topic = record.dig("notification", "SnsConfiguration", "TopicArn").to_s
      return topic if topic.start_with?("http://", "https://")

      self.class.notification_url
    end

    def deliver(url, payload)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 2
      http.read_timeout = 5

      request = Net::HTTP::Post.new(uri.request_uri, "content-type" => "application/json")
      request.body = JSON.dump(payload)
      response = http.request(request)
      Log.event("notification", url: url, code: response.code)
      response
    rescue StandardError => e
      # A receiver that is down must not turn a successful run into a failed one.
      warn("[timestream-local] notification POST to #{url} failed: #{e.class}: #{e.message}")
      Log.event("notification", url: url, error: e.class, message: e.message)
    end

    def description(record)
      {
        "Arn" => record["arn"], "Name" => record["name"], "QueryString" => record["query_string"],
        "State" => record["state"], "CreationTime" => record["created_at"],
        "ScheduleConfiguration" => record["schedule"],
        "NotificationConfiguration" => record["notification"],
        "TargetConfiguration" => presence(record["target"]),
        "ScheduledQueryExecutionRoleArn" => record["execution_role_arn"],
        "KmsKeyId" => record["kms_key_id"],
        "ErrorReportConfiguration" => presence(record["error_report"]),
        "PreviousInvocationTime" => record.dig("last_run", "invocation_time"),
        "LastRunSummary" => last_run_summary(record)
      }.compact
    end

    def last_run_summary(record)
      run = record["last_run"] or return nil

      {
        "InvocationTime" => run["invocation_time"],
        "TriggerTime" => run["triggerTimeMillis"] && run["triggerTimeMillis"] / 1000.0,
        "RunStatus" => run["run_status"],
        "FailureReason" => run["failureReason"],
        "ExecutionStats" => {
          "ExecutionTimeInMillis" => run.dig("executionStats", "executionTimeInMillis"),
          "DataWrites" => run.dig("executionStats", "dataWrites"),
          "BytesMetered" => run.dig("executionStats", "bytesMetered"),
          "RecordsIngested" => run.dig("executionStats", "recordsIngested"),
          "QueryResultRows" => run.dig("executionStats", "queryResultRows")
        }.compact
      }.compact
    end

    def target_destination(record)
      configuration = record.dig("target", "TimestreamConfiguration") or return nil

      { "TimestreamDestination" => { "DatabaseName" => configuration["DatabaseName"],
                                     "TableName" => configuration["TableName"] } }
    end

    # InvocationTime arrives as epoch seconds under AWS JSON, and the completion
    # callback has to echo it back unchanged -- a receiver matching runs on that
    # value treats a re-derived or rounded one as a stale callback and ignores it.
    def parse_invocation_time(value)
      raise ValidationException, "InvocationTime is required" if value.nil?

      case value
      when Numeric then value.to_i
      when String then value.match?(/\A-?\d+(\.\d+)?\z/) ? value.to_f.to_i : Time.parse(value).to_i
      else raise ValidationException, "InvocationTime #{value.inspect} is not a timestamp"
      end
    end

    def require_arn(params)
      arn = params["ScheduledQueryArn"]
      raise ValidationException, "ScheduledQueryArn is required" if blank?(arn)

      arn
    end

    def presence(value)
      value.nil? || value.empty? ? nil : value
    end

    def blank?(value)
      value.nil? || value.to_s.empty?
    end

    def now_monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
