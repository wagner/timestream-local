# frozen_string_literal: true

require "json"

module TimestreamLocal
  # Rack application speaking AWS JSON 1.0.
  #
  # Timestream Write and Timestream Query share the `Timestream_20181101`
  # target prefix and their operation names do not collide, so both services
  # are served from a single port. `DescribeEndpoints` exists in both, but the
  # response shape is identical, so the overlap is harmless.
  class Server
    TARGET_PREFIX = "Timestream_20181101"
    CONTENT_TYPE = "application/x-amz-json-1.0"

    WRITE_OPERATIONS = %w[
      CreateDatabase DeleteDatabase DescribeDatabase ListDatabases UpdateDatabase
      CreateTable DeleteTable DescribeTable ListTables UpdateTable
      WriteRecords ListTagsForResource
    ].freeze
    QUERY_OPERATIONS = %w[Query CancelQuery PrepareQuery].freeze

    PIPELINED_REQUEST_RE = %r{\b(?:GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH)\s+\S+\s+HTTP/\d}
    SCHEDULED_QUERY_OPERATIONS = %w[
      CreateScheduledQuery DeleteScheduledQuery DescribeScheduledQuery
      ListScheduledQueries ExecuteScheduledQuery
    ].freeze

    class << self
      # Address handed back by DescribeEndpoints. Returned with an explicit
      # scheme: SDKs only prepend https:// when the address has none, so keeping
      # the scheme keeps clients on plain HTTP.
      attr_writer :advertised_address

      def advertised_address
        @advertised_address ||= ENV.fetch("TIMESTREAM_LOCAL_ADVERTISED_ENDPOINT", "http://localhost:8080")
      end
    end

    attr_reader :store, :operation_log, :scheduled_query_api

    def initialize(store)
      @store = store
      @write_api = WriteApi.new(store)
      @query_api = QueryApi.new(store)
      @scheduled_query_api = ScheduledQueryApi.new(store, @write_api, @query_api)
      @web_ui = WebUi.new(store, @query_api)
      @operation_log = []
      @log_mutex = Mutex.new
    end

    def call(env)
      method = env["REQUEST_METHOD"]
      path = env["PATH_INFO"]

      # /__operations records which RPCs the SDK actually issued -- it is how
      # the test suite asserts that no DescribeEndpoints call was made.
      if method == "GET" && path == "/" && WebUi.enabled?
        @web_ui.call(env)
      elsif method == "GET" && path == "/health"
        text(200, "ok")
      elsif method == "GET" && path == "/__operations"
        json(200, @log_mutex.synchronize { @operation_log.dup })
      elsif method == "DELETE" && path == "/__operations"
        @log_mutex.synchronize { @operation_log.clear }
        text(200, "ok")
      else
        handle_rpc(env)
      end
    end

    private

    def handle_rpc(env)
      return text(405, "Method Not Allowed") unless env["REQUEST_METHOD"] == "POST"

      operation = target_operation(env)
      return unknown_operation("missing X-Amz-Target header") if operation.nil?

      @log_mutex.synchronize { @operation_log << operation }
      params = parse_body(env)
      json(200, dispatch(operation, params))
    rescue ApiError => e
      error_response(e)
    rescue JSON::ParserError => e
      error_response(ValidationException.new("Malformed request body: #{e.message}"))
    rescue StandardError => e
      warn("[timestream-local] #{e.class}: #{e.message}\n  #{e.backtrace&.first(5)&.join("\n  ")}")
      error_response(InternalServerException.new(e.message))
    end

    def dispatch(operation, params)
      if operation == "DescribeEndpoints"
        @write_api.describe_endpoints(params)
      elsif WRITE_OPERATIONS.include?(operation)
        @write_api.public_send(snake_case(operation), params)
      elsif QUERY_OPERATIONS.include?(operation)
        @query_api.public_send(snake_case(operation), params)
      elsif SCHEDULED_QUERY_OPERATIONS.include?(operation)
        @scheduled_query_api.public_send(snake_case(operation), params)
      else
        raise UnknownOperation, operation
      end
    end

    def target_operation(env)
      target = env["HTTP_X_AMZ_TARGET"]
      return nil if target.nil? || target.empty?

      prefix, _, operation = target.rpartition(".")
      return nil unless prefix == TARGET_PREFIX

      operation
    end

    def parse_body(env)
      body = env["rack.input"]&.read.to_s
      return {} if body.empty?

      parsed =
        begin
          JSON.parse(body)
        rescue JSON::ParserError => e
          raise ValidationException, malformed_body_message(body, e)
        end
      raise ValidationException, "Request body must be a JSON object" unless parsed.is_a?(Hash)

      parsed
    end

    # A body carrying the start of another HTTP request is not really a malformed
    # request: it is two processes writing into one socket, which is what happens
    # when an HTTP connection pool is inherited across fork. Saying so turns a
    # confusing parse error into an actionable one.
    def malformed_body_message(body, error)
      message = "Malformed request body: #{error.message}"
      return message unless body.match?(PIPELINED_REQUEST_RE)

      "#{message}. The body contains the start of another HTTP request, which usually means a client " \
        "connection pool was inherited across fork and more than one process is writing to the same " \
        "connection. Give each forked process its own connections."
    end

    def snake_case(operation)
      operation.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end

    def error_response(error)
      body = { "__type" => "com.amazonaws.timestream##{error.code}", "message" => error.message }
        .merge(error.body)
      [error.status,
       { "content-type" => CONTENT_TYPE, "x-amzn-errortype" => error.code, "x-amzn-requestid" => request_id },
       [JSON.dump(body)]]
    end

    def unknown_operation(message)
      error_response(ValidationException.new(message))
    end

    def json(status, payload)
      [status,
       { "content-type" => CONTENT_TYPE, "x-amzn-requestid" => request_id },
       [JSON.dump(payload)]]
    end

    def text(status, message)
      [status, { "content-type" => "text/plain" }, [message]]
    end

    def request_id
      SecureRandom.uuid
    end

    # Raised for targets we do not implement; surfaces the same way AWS does.
    class UnknownOperation < ApiError
      def initialize(operation)
        super("Operation #{operation} is not supported by timestream-local")
      end

      def code
        "UnknownOperationException"
      end
    end
  end
end
