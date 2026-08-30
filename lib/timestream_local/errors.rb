# frozen_string_literal: true

module TimestreamLocal
  # Maps onto the modeled Timestream exceptions. The AWS JSON 1.0 protocol
  # carries the error code in the `x-amzn-errortype` header and/or the `__type`
  # body member; we send both so every SDK resolves the right error class.
  class ApiError < StandardError
    attr_reader :body

    def initialize(message, body: {})
      super(message)
      @body = body
    end

    def code
      self.class.name.split("::").last
    end

    def status
      400
    end
  end

  class ValidationException < ApiError; end
  class ResourceNotFoundException < ApiError; end
  class ConflictException < ApiError; end
  class InvalidEndpointException < ApiError; end
  class QueryExecutionException < ApiError; end
  class ServiceQuotaExceededException < ApiError; end

  class InternalServerException < ApiError
    def status
      500
    end
  end

  # WriteRecords reports per-record failures rather than failing the batch.
  class RejectedRecordsException < ApiError
    def initialize(rejected)
      super("One or more records have been rejected.",
            body: { "RejectedRecords" => rejected })
    end
  end
end
