# frozen_string_literal: true

require_relative "test_helper"

# Every Timestream operation except DescribeEndpoints is modelled with
# `endpointdiscovery: {required: true}`, which normally makes the SDK resolve a
# cell endpoint before each call and replace the request URL with it.
#
# In aws-sdk-ruby the discovery handler is only installed when
# `config.regional_endpoint` is true, and RegionalEndpoint#resolve_endpoint only
# sets that flag when no custom endpoint was configured. These tests pin that
# behaviour down empirically rather than trusting the source read.
class EndpointDiscoveryTest < TimestreamTest
  def test_write_client_with_custom_endpoint_does_not_discover
    clear_operations
    database_name = unique("db")
    write_client.create_database(database_name: database_name)
    write_client.delete_database(database_name: database_name)

    assert_equal %w[CreateDatabase DeleteDatabase], operations
    refute_includes operations, "DescribeEndpoints"
  end

  def test_query_client_with_custom_endpoint_does_not_discover
    with_table do |database_name, table_name|
      clear_operations
      query_client.query(query_string: %(SELECT * FROM "#{database_name}"."#{table_name}"))

      assert_equal %w[Query], operations
    end
  end

  def test_describe_endpoints_is_served_for_clients_that_do_discover
    response = write_client.describe_endpoints

    assert_equal 1, response.endpoints.size
    address = response.endpoints.first.address
    # The scheme is deliberately included: SDKs only prepend https:// when the
    # address has none, so keeping it here keeps discovering clients on HTTP.
    assert address.start_with?("http://"), "expected an http:// address, got #{address.inspect}"
    assert_operator response.endpoints.first.cache_period_in_minutes, :>=, 1
  end

  def test_query_client_describe_endpoints_matches
    assert_equal write_client.describe_endpoints.endpoints.first.address,
                 query_client.describe_endpoints.endpoints.first.address
  end

  def test_unknown_operation_is_reported_as_such
    error = assert_raises(Aws::TimestreamWrite::Errors::ServiceError) do
      write_client.create_batch_load_task(
        target_database_name: "db", target_table_name: "tbl",
        data_model_configuration: { data_model: { dimension_mappings: [] } },
        data_source_configuration: {
          data_source_s3_configuration: { bucket_name: "b" }, data_format: "CSV"
        },
        report_configuration: {}
      )
    end
    assert_match(/not supported by timestream-local/, error.message)
  end
end
