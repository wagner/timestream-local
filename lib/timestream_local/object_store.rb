# frozen_string_literal: true

module TimestreamLocal
  # S3-compatible storage, used only by UNLOAD.
  #
  # Optional by design. Nothing here is configured by default and no credentials
  # are held, so the server neither reaches the network nor needs an S3 to run --
  # UNLOAD simply reports itself unsupported until an endpoint is set. Point it at
  # minio, localstack or anything else that speaks S3; nothing AWS-specific is
  # assumed beyond the protocol.
  class ObjectStore
    DEFAULT_REGION = "us-east-1"

    class NotConfigured < StandardError; end

    class << self
      attr_writer :endpoint, :access_key_id, :secret_access_key, :region

      def endpoint
        setting(:@endpoint, "TIMESTREAM_LOCAL_S3_ENDPOINT")
      end

      def access_key_id
        setting(:@access_key_id, "TIMESTREAM_LOCAL_S3_ACCESS_KEY_ID") || "minioadmin"
      end

      def secret_access_key
        setting(:@secret_access_key, "TIMESTREAM_LOCAL_S3_SECRET_ACCESS_KEY") || "minioadmin"
      end

      def region
        setting(:@region, "TIMESTREAM_LOCAL_S3_REGION") || DEFAULT_REGION
      end

      def configured?
        !endpoint.nil?
      end

      def build
        raise NotConfigured unless configured?

        new(endpoint: endpoint, access_key_id: access_key_id,
            secret_access_key: secret_access_key, region: region)
      end

      # Explicitly assigned nil still counts as assigned, so a test can turn the
      # endpoint off without the environment leaking back in.
      def setting(variable, env_name)
        return instance_variable_get(variable) if instance_variable_defined?(variable)

        value = ENV.fetch(env_name, nil)
        value.nil? || value.empty? ? nil : value
      end

      def reset!
        %i[@endpoint @access_key_id @secret_access_key @region].each do |variable|
          remove_instance_variable(variable) if instance_variable_defined?(variable)
        end
      end
    end

    def initialize(endpoint:, access_key_id:, secret_access_key:, region:)
      # Required lazily: the SDK is only needed when UNLOAD is actually used, and
      # the server has to boot without it.
      require "aws-sdk-s3"

      @client = Aws::S3::Client.new(
        endpoint: endpoint, region: region, force_path_style: true,
        credentials: Aws::Credentials.new(access_key_id, secret_access_key),
        retry_limit: 1
      )
    end

    def put(bucket, key, body, content_type: "application/octet-stream")
      ensure_bucket(bucket)
      @client.put_object(bucket: bucket, key: key, body: body, content_type: content_type)
      url(bucket, key)
    end

    def url(bucket, key)
      "s3://#{bucket}/#{key}"
    end

    private

    # Real Timestream requires the bucket to exist. Creating it here removes a
    # setup step locally and cannot produce a wrong result, since the same name is
    # written and read back.
    def ensure_bucket(bucket)
      @client.head_bucket(bucket: bucket)
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchBucket, Aws::S3::Errors::Http404Error
      @client.create_bucket(bucket: bucket)
    rescue Aws::S3::Errors::BucketAlreadyOwnedByYou, Aws::S3::Errors::BucketAlreadyExists
      nil
    end
  end
end
