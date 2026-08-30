# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "net/http"
require "securerandom"

require "aws-sdk-timestreamquery"
require "aws-sdk-timestreamwrite"

require_relative "../lib/timestream_local"

# The suite drives the real AWS Ruby SDK clients over HTTP.
#
# By default it boots the Rack app in-process on an ephemeral port. Point
# TIMESTREAM_LOCAL_ENDPOINT at the container to run the identical suite against
# the published image:
#
#   docker-compose up -d
#   TIMESTREAM_LOCAL_ENDPOINT=http://localhost:8080 bundle exec rake test
module TestServer
  module_function

  def endpoint
    @endpoint ||= ENV["TIMESTREAM_LOCAL_ENDPOINT"] || boot_in_process
  end

  def boot_in_process
    require "puma"

    app = TimestreamLocal.build(path: ":memory:")
    server = Puma::Server.new(app)
    port = server.add_tcp_listener("127.0.0.1", 0).addr[1]
    TimestreamLocal::Server.advertised_address = "http://127.0.0.1:#{port}"
    server.run
    at_exit do
      server.stop(true)
    rescue StandardError
      nil
    end
    "http://127.0.0.1:#{port}"
  end
end

class TimestreamTest < Minitest::Test
  CREDENTIALS = Aws::Credentials.new("test", "test")
  REGION = "us-east-1"

  def endpoint
    TestServer.endpoint
  end

  def write_client
    @write_client ||= Aws::TimestreamWrite::Client.new(client_options)
  end

  def query_client
    @query_client ||= Aws::TimestreamQuery::Client.new(client_options)
  end

  def client_options
    { endpoint: endpoint, region: REGION, credentials: CREDENTIALS, retry_limit: 0 }
  end

  # Operations the server actually received -- used to prove the SDK is not
  # issuing endpoint-discovery round trips.
  def operations
    JSON.parse(Net::HTTP.get(URI("#{endpoint}/__operations")))
  end

  def clear_operations
    uri = URI("#{endpoint}/__operations")
    Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Delete.new(uri))
  end

  def unique(prefix)
    "#{prefix}_#{SecureRandom.hex(4)}"
  end

  # Creates a database + table that are cleaned up when the test finishes.
  def with_table
    database_name = unique("db")
    table_name = unique("tbl")
    write_client.create_database(database_name: database_name)
    write_client.create_table(database_name: database_name, table_name: table_name)
    yield database_name, table_name
  ensure
    begin
      write_client.delete_table(database_name: database_name, table_name: table_name)
      write_client.delete_database(database_name: database_name)
    rescue Aws::Errors::ServiceError
      nil
    end
  end

  def rows_as_hashes(response)
    columns = response.column_info.map(&:name)
    response.rows.map do |row|
      columns.zip(row.data.map { |datum| datum.null_value ? nil : datum.scalar_value }).to_h
    end
  end

  def millis(time)
    (time.to_f * 1000).round.to_s
  end
end
