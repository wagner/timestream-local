# frozen_string_literal: true

require_relative "test_helper"

class WriteApiTest < TimestreamTest
  # A body containing another HTTP request means a connection pool was shared
  # across forked processes, not that the request was malformed. The message says so.
  def test_malformed_body_naming_a_forked_connection_pool
    uri = URI("#{endpoint}/")
    request = Net::HTTP::Post.new(uri)
    request["X-Amz-Target"] = "Timestream_20181101.ListDatabases"
    request["content-type"] = "application/x-amz-json-1.0"
    request.body = %({"DatabaseName": "a"} POST / HTTP/1.1\r\nAccept-Encoding: gzip)

    response = Net::HTTP.new(uri.host, uri.port).request(request)
    assert_equal "400", response.code
    assert_match(/inherited across fork/, JSON.parse(response.body)["message"])
  end

  def test_database_lifecycle
    database_name = unique("db")

    created = write_client.create_database(database_name: database_name)
    assert_equal database_name, created.database.database_name
    assert_match %r{\Aarn:aws:timestream:us-east-1:\d+:database/#{database_name}\z}, created.database.arn
    assert_kind_of Time, created.database.creation_time

    assert_equal 0, write_client.describe_database(database_name: database_name).database.table_count
    assert_includes write_client.list_databases.databases.map(&:database_name), database_name

    write_client.delete_database(database_name: database_name)
    assert_raises(Aws::TimestreamWrite::Errors::ResourceNotFoundException) do
      write_client.describe_database(database_name: database_name)
    end
  end

  def test_duplicate_database_conflicts
    database_name = unique("db")
    write_client.create_database(database_name: database_name)

    assert_raises(Aws::TimestreamWrite::Errors::ConflictException) do
      write_client.create_database(database_name: database_name)
    end
  ensure
    write_client.delete_database(database_name: database_name)
  end

  def test_table_lifecycle_with_retention
    database_name = unique("db")
    table_name = unique("tbl")
    write_client.create_database(database_name: database_name)

    created = write_client.create_table(
      database_name: database_name, table_name: table_name,
      retention_properties: {
        memory_store_retention_period_in_hours: 12,
        magnetic_store_retention_period_in_days: 30
      }
    )
    assert_equal "ACTIVE", created.table.table_status
    assert_equal 12, created.table.retention_properties.memory_store_retention_period_in_hours
    assert_equal 30, created.table.retention_properties.magnetic_store_retention_period_in_days

    assert_equal [table_name], write_client.list_tables(database_name: database_name).tables.map(&:table_name)
    assert_equal 1, write_client.describe_database(database_name: database_name).database.table_count

    updated = write_client.update_table(
      database_name: database_name, table_name: table_name,
      retention_properties: {
        memory_store_retention_period_in_hours: 24,
        magnetic_store_retention_period_in_days: 60
      }
    )
    assert_equal 24, updated.table.retention_properties.memory_store_retention_period_in_hours

    write_client.delete_table(database_name: database_name, table_name: table_name)
    write_client.delete_database(database_name: database_name)
  end

  def test_creating_a_table_in_a_missing_database_fails
    assert_raises(Aws::TimestreamWrite::Errors::ResourceNotFoundException) do
      write_client.create_table(database_name: unique("missing"), table_name: unique("tbl"))
    end
  end

  def test_write_single_measure_records
    with_table do |database_name, table_name|
      now = Time.now
      response = write_client.write_records(
        database_name: database_name, table_name: table_name,
        records: [
          {
            dimensions: [{ name: "device_id", value: "sensor-1" }],
            measure_name: "temperature", measure_value: "35.5", measure_value_type: "DOUBLE",
            time: millis(now)
          },
          {
            dimensions: [{ name: "device_id", value: "sensor-1" }],
            measure_name: "moisture", measure_value: "21", measure_value_type: "BIGINT",
            time: millis(now)
          }
        ]
      )

      assert_equal 2, response.records_ingested.total
      assert_equal 2, response.records_ingested.memory_store
      assert_equal 0, response.records_ingested.magnetic_store

      rows = rows_as_hashes(
        query_client.query(query_string: %(SELECT * FROM "#{database_name}"."#{table_name}" ORDER BY measure_name))
      )
      assert_equal %w[moisture temperature], rows.map { |row| row["measure_name"] }
      assert_equal "21", rows[0]["measure_value::bigint"]
      assert_nil rows[0]["measure_value::double"]
      assert_equal "35.5", rows[1]["measure_value::double"]
      assert_equal "sensor-1", rows[1]["device_id"]
    end
  end

  def test_write_multi_measure_records
    with_table do |database_name, table_name|
      write_client.write_records(
        database_name: database_name, table_name: table_name,
        records: [{
          dimensions: [{ name: "hostname", value: "host-24Gju" }],
          measure_name: "metrics", measure_value_type: "MULTI",
          measure_values: [
            { name: "cpu", value: "35.0", type: "DOUBLE" },
            { name: "memory", value: "54.9", type: "DOUBLE" },
            { name: "disk_iops", value: "38", type: "BIGINT" },
            { name: "healthy", value: "true", type: "BOOLEAN" },
            { name: "region", value: "us-east-1", type: "VARCHAR" }
          ],
          time: millis(Time.now)
        }]
      )

      row = rows_as_hashes(
        query_client.query(query_string: %(SELECT * FROM "#{database_name}"."#{table_name}"))
      ).first

      assert_equal "host-24Gju", row["hostname"]
      assert_equal "metrics", row["measure_name"]
      assert_equal "35.0", row["cpu"]
      assert_equal "54.9", row["memory"]
      assert_equal "38", row["disk_iops"]
      assert_equal "true", row["healthy"]
      assert_equal "us-east-1", row["region"]
    end
  end

  def test_common_attributes_are_merged_into_every_record
    with_table do |database_name, table_name|
      now = Time.now
      write_client.write_records(
        database_name: database_name, table_name: table_name,
        common_attributes: {
          dimensions: [{ name: "region", value: "us-east-1" }],
          measure_name: "cpu", measure_value_type: "DOUBLE", time: millis(now)
        },
        records: [
          { dimensions: [{ name: "host", value: "a" }], measure_value: "10.0" },
          { dimensions: [{ name: "host", value: "b" }], measure_value: "20.0" }
        ]
      )

      rows = rows_as_hashes(
        query_client.query(query_string: %(SELECT * FROM "#{database_name}"."#{table_name}" ORDER BY host))
      )
      assert_equal %w[a b], rows.map { |row| row["host"] }
      assert_equal %w[us-east-1 us-east-1], rows.map { |row| row["region"] }
      assert_equal %w[cpu cpu], rows.map { |row| row["measure_name"] }
      assert_equal %w[10.0 20.0], rows.map { |row| row["measure_value::double"] }
    end
  end

  def test_overlapping_dimensions_are_rejected
    with_table do |database_name, table_name|
      error = assert_raises(Aws::TimestreamWrite::Errors::RejectedRecordsException) do
        write_client.write_records(
          database_name: database_name, table_name: table_name,
          common_attributes: { dimensions: [{ name: "host", value: "a" }] },
          records: [{
            dimensions: [{ name: "host", value: "b" }],
            measure_name: "cpu", measure_value: "1.0", measure_value_type: "DOUBLE",
            time: millis(Time.now)
          }]
        )
      end
      assert_match(/may not overlap/, error.rejected_records.first.reason)
    end
  end

  # Identity is (dimensions, measure_name, time). A higher Version overwrites;
  # an equal or lower one is rejected with the current version reported back.
  def test_version_controls_upserts
    with_table do |database_name, table_name|
      timestamp = millis(Time.now)
      record = {
        dimensions: [{ name: "device_id", value: "sensor-1" }],
        measure_name: "temperature", measure_value_type: "DOUBLE", time: timestamp
      }

      write_client.write_records(
        database_name: database_name, table_name: table_name,
        records: [record.merge(measure_value: "35.0")]
      )
      write_client.write_records(
        database_name: database_name, table_name: table_name,
        records: [record.merge(measure_value: "36.0", version: 2)]
      )

      rows = rows_as_hashes(
        query_client.query(query_string: %(SELECT * FROM "#{database_name}"."#{table_name}"))
      )
      assert_equal 1, rows.size, "the second write should update in place, not append"
      assert_equal "36.0", rows.first["measure_value::double"]

      error = assert_raises(Aws::TimestreamWrite::Errors::RejectedRecordsException) do
        write_client.write_records(
          database_name: database_name, table_name: table_name,
          records: [record.merge(measure_value: "37.0")]
        )
      end
      rejected = error.rejected_records.first
      assert_equal 0, rejected.record_index
      assert_equal 2, rejected.existing_version
    end
  end

  def test_partial_batches_ingest_the_valid_records
    with_table do |database_name, table_name|
      error = assert_raises(Aws::TimestreamWrite::Errors::RejectedRecordsException) do
        write_client.write_records(
          database_name: database_name, table_name: table_name,
          records: [
            {
              dimensions: [{ name: "device_id", value: "ok" }],
              measure_name: "temperature", measure_value: "1.0", measure_value_type: "DOUBLE",
              time: millis(Time.now)
            },
            {
              dimensions: [{ name: "device_id", value: "bad" }],
              measure_name: "temperature", measure_value: "not-a-number", measure_value_type: "DOUBLE",
              time: millis(Time.now)
            }
          ]
        )
      end

      assert_equal [1], error.rejected_records.map(&:record_index)
      rows = rows_as_hashes(
        query_client.query(query_string: %(SELECT * FROM "#{database_name}"."#{table_name}"))
      )
      assert_equal ["ok"], rows.map { |row| row["device_id"] }
    end
  end

  def test_writing_to_a_missing_table_fails
    assert_raises(Aws::TimestreamWrite::Errors::ResourceNotFoundException) do
      write_client.write_records(
        database_name: unique("db"), table_name: unique("tbl"),
        records: [{ measure_name: "cpu", measure_value: "1.0", time: millis(Time.now) }]
      )
    end
  end

  def test_time_units_are_honoured
    with_table do |database_name, table_name|
      write_client.write_records(
        database_name: database_name, table_name: table_name,
        records: [{
          dimensions: [{ name: "device_id", value: "sensor-1" }],
          measure_name: "temperature", measure_value: "1.0", measure_value_type: "DOUBLE",
          time: "1638385200", time_unit: "SECONDS"
        }]
      )

      row = rows_as_hashes(
        query_client.query(query_string: %(SELECT time FROM "#{database_name}"."#{table_name}"))
      ).first
      assert_equal "2021-12-01 19:00:00.000000000", row["time"]
    end
  end
end
