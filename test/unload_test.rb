# frozen_string_literal: true

require "digest"
require "zlib"

require_relative "test_helper"
require_relative "support/fake_s3"

# UNLOAD writes its rows to object storage and returns only a summary naming the
# manifest. The caller reads the manifest, then the files it lists.
class UnloadTest < TimestreamTest
  AT = Time.utc(2026, 4, 28, 18, 12, 7)
  BUCKET = "timestream-exports-dev"
  PREFIX = "2025-04-28t18-12-07z"

  def setup
    @s3 = nil
    @s3_server = nil
  end

  def teardown
    @s3_server&.stop(true)
    TimestreamLocal::ObjectStore.reset!
    TimestreamLocal::Query::Unload.reset_max_rows_per_file!
  rescue StandardError
    nil
  end

  # Execution needs the server and the object store in this process. Against an
  # external server, its storage is not ours to inspect.
  def in_process_only
    skip "UNLOAD execution is asserted in-process" if ENV["TIMESTREAM_LOCAL_ENDPOINT"]
  end

  def with_object_store
    require "puma"

    @s3 = FakeS3.new
    @s3_server = Puma::Server.new(@s3)
    port = @s3_server.add_tcp_listener("127.0.0.1", 0).addr[1]
    @s3_server.run
    TimestreamLocal::ObjectStore.endpoint = "http://127.0.0.1:#{port}"
    @s3
  end

  def seed(database_name, table_name, count: 3)
    records = count.times.map do |index|
      {
        dimensions: [{ name: "external_id", value: "pay_#{index}" }],
        measure_name: "payment", measure_value: ((index + 1) * 100).to_s, measure_value_type: "BIGINT",
        time: millis(AT + index)
      }
    end
    write_client.write_records(database_name: database_name, table_name: table_name, records: records)
  end

  def unload(inner, options: "format = 'CSV', compression = 'NONE', include_header = 'false'")
    query_client.query(query_string: <<~SQL)
      UNLOAD (#{inner})
        TO 's3://#{BUCKET}/#{PREFIX}'
        WITH (#{options})
    SQL
  end

  def summary(response)
    rows_as_hashes(response).first
  end

  def manifest_for(response)
    url = summary(response)["manifestFile"]
    JSON.parse(@s3.object(BUCKET, url.delete_prefix("s3://#{BUCKET}/")))
  end

  def result_bodies(manifest, gzip: false)
    raw_result_bodies(manifest).map do |body|
      gzip ? Zlib::GzipReader.new(StringIO.new(body)).read : body
    end
  end

  def raw_result_bodies(manifest)
    manifest["result_files"].map { |file| @s3.object(BUCKET, file["url"].delete_prefix("s3://#{BUCKET}/")) }
  end

  # Row order across files has to match the query's, since the reader
  # concatenates them in manifest order.
  def ordered_select(database_name, table_name)
    <<~SQL.strip
      SELECT external_id as external_id FROM "#{database_name}"."#{table_name}"
      ORDER BY "#{database_name}"."#{table_name}".time ASC
    SQL
  end

  # ------------------------------------------------------------------- parsing

  # The inner query has its own parentheses and string literals, so the closing
  # paren has to be counted rather than matched.
  def test_parses_a_query_containing_parentheses_and_literals
    statement = TimestreamLocal::Query::Unload.parse(<<~SQL)
      UNLOAD (SELECT count(*) AS n, IF(x > 1, 'a)b', 'c') AS l FROM "db"."t" WHERE s = 'to ''x''')
        TO 's3://bucket/some/prefix'
        WITH (format = 'CSV', compression = 'NONE', field_delimiter = ',', escaped_by = '\\', include_header = 'false')
    SQL

    assert_equal "bucket", statement.bucket
    assert_equal "some/prefix", statement.prefix
    assert_includes statement.query, "count(*)"
    assert_includes statement.query, "'a)b'"
    assert_equal "CSV", statement.options["format"]
    assert_equal "NONE", statement.options["compression"]
    assert_equal "false", statement.options["include_header"]
    assert_equal "\\", statement.options["escaped_by"]
  end

  def test_rejects_a_destination_that_is_not_s3
    error = assert_raises(TimestreamLocal::ValidationException) do
      TimestreamLocal::Query::Unload.parse(%(UNLOAD (SELECT 1) TO 'file:///tmp/x' WITH (format = 'CSV')))
    end
    assert_match(%r{must be an s3:// URL}, error.message)
  end

  def test_requires_a_destination
    assert_raises(TimestreamLocal::ValidationException) do
      TimestreamLocal::Query::Unload.parse(%(UNLOAD (SELECT 1) WITH (format = 'CSV')))
    end
  end

  # ---------------------------------------------------------------- unsupported

  def test_unload_without_an_object_store_is_rejected_loudly
    in_process_only
    TimestreamLocal::ObjectStore.endpoint = nil

    error = assert_raises(Aws::TimestreamQuery::Errors::ValidationException) do
      unload("SELECT 1 AS n")
    end
    assert_match(/TIMESTREAM_LOCAL_S3_ENDPOINT/, error.message)
  end

  # -------------------------------------------------------------------- writing

  def test_unload_writes_csv_and_returns_a_manifest
    in_process_only
    with_object_store

    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = unload(<<~SQL.strip)
        SELECT to_iso8601(time) as time, external_id as external_id,
               CAST(measure_value::bigint AS DOUBLE)/100 as amount
        FROM "#{database_name}"."#{table_name}"
        ORDER BY "#{database_name}"."#{table_name}".time ASC LIMIT 10000000
      SQL

      row = summary(response)
      assert_equal %w[rows metadataFile manifestFile], response.column_info.map(&:name)
      assert_equal "3", row["rows"]
      assert_equal "BIGINT", response.column_info.first.type.scalar_type

      manifest = manifest_for(response)
      assert_equal 1, manifest["result_files"].size
      assert_match(%r{\As3://#{BUCKET}/#{PREFIX}/}, manifest["result_files"].first["url"])
      assert_equal 3, manifest["result_files"].first.dig("file_metadata", "row_count")
      assert_operator manifest["query_metadata"]["content_length_in_bytes"], :>, 0
      assert_operator manifest["query_metadata"]["total_bytes_scanned"], :>, 0

      body = result_bodies(manifest).first
      assert_equal ["2026-04-28T18:12:07.000000000,pay_0,1.0",
                    "2026-04-28T18:12:08.000000000,pay_1,2.0",
                    "2026-04-28T18:12:09.000000000,pay_2,3.0"], body.lines.map(&:chomp)
    end
  end

  # Load-bearing: the caller writes its own header when concatenating result
  # files, so a header in the files would land in the middle of the CSV.
  def test_include_header_false_omits_the_header_row
    in_process_only
    with_object_store

    with_table do |database_name, table_name|
      seed(database_name, table_name, count: 1)
      inner = %(SELECT external_id as external_id FROM "#{database_name}"."#{table_name}")

      body = result_bodies(manifest_for(unload(inner))).first
      assert_equal ["pay_0"], body.lines.map(&:chomp)

      body = result_bodies(manifest_for(
        unload(inner, options: "format = 'CSV', compression = 'NONE', include_header = 'true'")
      )).first
      assert_equal %w[external_id pay_0], body.lines.map(&:chomp)
    end
  end

  # An empty export is a normal outcome the caller reports as such, not an error.
  def test_an_empty_result_returns_zero_rows_and_an_empty_manifest
    in_process_only
    with_object_store

    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = unload(%(SELECT external_id as external_id FROM "#{database_name}"."#{table_name}" WHERE external_id = 'nobody'))

      assert_equal "0", summary(response)["rows"]
      assert_empty manifest_for(response)["result_files"]
    end
  end

  def test_gzip_compression
    in_process_only
    with_object_store

    with_table do |database_name, table_name|
      seed(database_name, table_name, count: 1)

      response = unload(%(SELECT external_id as external_id FROM "#{database_name}"."#{table_name}"),
                        options: "format = 'CSV', compression = 'GZIP', include_header = 'false'")
      manifest = manifest_for(response)

      assert_match(/\.csv\.gz\z/, manifest["result_files"].first["url"])
      assert_equal ["pay_0"], result_bodies(manifest, gzip: true).first.lines.map(&:chomp)
    end
  end

  # ---------------------------------------------------------------- splitting

  # Real Timestream splits a large result across several files. A reader that
  # follows the manifest sees every row exactly once, in query order, with the
  # header carried by the first file only -- repeating it per file would land a
  # header row in the middle of the concatenation.
  def test_a_large_result_is_split_across_several_files
    in_process_only
    with_object_store
    TimestreamLocal::Query::Unload.max_rows_per_file = 2

    with_table do |database_name, table_name|
      seed(database_name, table_name, count: 5)

      manifest = manifest_for(unload(ordered_select(database_name, table_name),
                                     options: "format = 'CSV', compression = 'NONE', include_header = 'true'"))

      files = manifest["result_files"]
      assert_equal 3, files.size
      assert_equal [2, 2, 1], files.map { |file| file.dig("file_metadata", "row_count") }

      bodies = result_bodies(manifest)
      assert_equal bodies.map(&:bytesize), files.map { |file| file.dig("file_metadata", "content_length_in_bytes") }
      assert_equal bodies.sum(&:bytesize), manifest["query_metadata"]["content_length_in_bytes"]

      assert_equal %w[external_id pay_0 pay_1 pay_2 pay_3 pay_4], bodies.join.lines.map(&:chomp)
      assert_equal 1, bodies.join.lines.count { |line| line.chomp == "external_id" }
    end
  end

  # Split or not, the reader is handed the same bytes.
  def test_splitting_does_not_change_the_concatenated_output
    in_process_only
    with_object_store

    with_table do |database_name, table_name|
      seed(database_name, table_name, count: 5)
      inner = ordered_select(database_name, table_name)

      whole = result_bodies(manifest_for(unload(inner))).join

      TimestreamLocal::Query::Unload.max_rows_per_file = 2
      manifest = manifest_for(unload(inner))

      assert_equal 3, manifest["result_files"].size
      assert_equal whole, result_bodies(manifest).join
      assert_equal "5", summary(unload(inner))["rows"]
    end
  end

  # Each part is its own gzip member, so it reads back on its own; concatenated
  # byte-for-byte they are one gzip document, which is how a reader consumes them.
  def test_each_part_of_a_gzip_result_is_independently_valid
    in_process_only
    with_object_store
    TimestreamLocal::Query::Unload.max_rows_per_file = 2

    with_table do |database_name, table_name|
      seed(database_name, table_name, count: 5)

      manifest = manifest_for(unload(ordered_select(database_name, table_name),
                                     options: "format = 'CSV', compression = 'GZIP', include_header = 'false'"))

      files = manifest["result_files"]
      assert_equal 3, files.size
      files.each { |file| assert_match(/\.csv\.gz\z/, file["url"]) }

      parts = raw_result_bodies(manifest)
      assert_equal [%w[pay_0 pay_1], %w[pay_2 pay_3], %w[pay_4]],
                   parts.map { |part| Zlib::GzipReader.new(StringIO.new(part)).read.lines.map(&:chomp) }
      assert_equal %w[pay_0 pay_1 pay_2 pay_3 pay_4],
                   Zlib::GzipReader.zcat(StringIO.new(parts.join)).lines.map(&:chomp)
    end
  end

  def test_delimiter_and_escaping
    in_process_only
    with_object_store

    with_table do |database_name, table_name|
      write_client.write_records(
        database_name: database_name, table_name: table_name,
        records: [{
          dimensions: [{ name: "label", value: %(a,b "quoted" c) }],
          measure_name: "m", measure_value: "1", measure_value_type: "BIGINT", time: millis(AT)
        }]
      )

      manifest = manifest_for(unload(
        %(SELECT label as label FROM "#{database_name}"."#{table_name}"),
        options: "format = 'CSV', compression = 'NONE', field_delimiter = ',', escaped_by = '\\', include_header = 'false'"
      ))

      # Quoted because it contains the delimiter and a quote; inner quotes take
      # the escape character rather than being doubled.
      assert_equal [%("a,b \\"quoted\\" c")], result_bodies(manifest).first.lines.map(&:chomp)
    end
  end

  def test_unsupported_format_is_rejected
    in_process_only
    with_object_store

    error = assert_raises(Aws::TimestreamQuery::Errors::ValidationException) do
      unload("SELECT 1 AS n", options: "format = 'PARQUET'")
    end
    assert_match(/only CSV/, error.message)
  end

  # The reader fetches result files with its own S3 client, streaming to a file.
  def test_result_files_are_retrievable_by_an_s3_client
    in_process_only
    with_object_store

    with_table do |database_name, table_name|
      seed(database_name, table_name, count: 1)
      manifest = manifest_for(unload(%(SELECT external_id as external_id FROM "#{database_name}"."#{table_name}")))

      require "aws-sdk-s3"
      client = Aws::S3::Client.new(
        endpoint: TimestreamLocal::ObjectStore.endpoint, region: "us-east-1", force_path_style: true,
        credentials: Aws::Credentials.new("minioadmin", "minioadmin")
      )
      url = manifest["result_files"].first["url"]
      object = client.get_object(bucket: BUCKET, key: url.delete_prefix("s3://#{BUCKET}/"))

      assert_equal "pay_0\n", object.body.read
    end
  end
end
