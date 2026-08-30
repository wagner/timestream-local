# frozen_string_literal: true

require "base64"
require "securerandom"

module TimestreamLocal
  # Implements the Timestream Query API on top of the SQLite views.
  class QueryApi
    MAX_ROWS_LIMIT = 1_000

    SHOW_DATABASES_RE = /\Ashow\s+databases\s*\z/i
    SHOW_TABLES_RE = /\Ashow\s+tables\s+(?:from|in)\s+(\S+)\s*\z/i
    SHOW_MEASURES_RE = /\Ashow\s+measures\s+(?:from|in)\s+(\S+)\s*\z/i
    DESCRIBE_RE = /\Adescribe\s+(\S+)\s*\z/i

    def initialize(store)
      @store = store
    end

    def query(params)
      query_string = params["QueryString"]
      raise ValidationException, "QueryString is required" if query_string.nil? || query_string.empty?

      max_rows = validate_max_rows(params["MaxRows"])
      offset = decode_token(params["NextToken"], query_string)

      columns, rows, types = run(query_string)
      page, next_offset = paginate(rows, offset, max_rows)

      response = {
        "QueryId" => SecureRandom.hex(16),
        "ColumnInfo" => columns.map { |name| { "Name" => name, "Type" => column_type(types[name]) } },
        "Rows" => page.map { |row| serialize_row(row, columns, types) },
        "QueryStatus" => {
          "ProgressPercentage" => 100.0,
          "CumulativeBytesScanned" => 0,
          "CumulativeBytesMetered" => 0
        }
      }
      response["NextToken"] = encode_token(query_string, next_offset) if next_offset
      response
    end

    def describe_endpoints(_params)
      { "Endpoints" => [{ "Address" => Server.advertised_address, "CachePeriodInMinutes" => 1 }] }
    end

    def cancel_query(_params)
      { "CancellationMessage" => "Query cancelled" }
    end

    # Used by the scheduled-query runner, which needs the resolved column types
    # to map results onto the target table's measures.
    def execute_statement(query_string, binds = [])
      run(query_string, binds)
    end

    def prepare_query(params)
      columns, = run(params["QueryString"])
      {
        "QueryString" => params["QueryString"],
        "Columns" => columns.map { |name| { "Name" => name } },
        "Parameters" => []
      }
    end

    private

    def run(query_string, binds = [])
      statement = query_string.strip.sub(/;\s*\z/, "")

      case statement
      when SHOW_DATABASES_RE then show_databases
      when SHOW_TABLES_RE then show_tables(Regexp.last_match(1))
      when SHOW_MEASURES_RE then show_measures(Regexp.last_match(1))
      when DESCRIBE_RE then describe(Regexp.last_match(1))
      else
        Query::Unload.statement?(statement) ? run_unload(statement) : run_select(statement, binds)
      end
    end

    # The rows go to object storage; what comes back is a one-row summary naming
    # the manifest. UNLOAD is unsupported until an S3 endpoint is configured --
    # loudly, rather than by writing nowhere.
    def run_unload(statement)
      unless ObjectStore.configured?
        raise ValidationException,
              "UNLOAD requires object storage. Set TIMESTREAM_LOCAL_S3_ENDPOINT to an S3-compatible " \
              "endpoint (minio, localstack) to enable it."
      end

      unload = Query::Unload.parse(statement)
      columns, rows, types = run_select(unload.query)
      Query::Unload.new(unload).call(columns, rows, types)
    end

    def run_select(statement, binds = [])
      rewritten = Query::Rewriter.new(statement).call
      rewritten.tables.each do |database_name, table_name|
        unless @store.table_exists?(database_name, table_name)
          raise QueryExecutionException,
                "Table #{database_name}.#{table_name} does not exist. " \
                "(line 1:1) Table #{database_name}.#{table_name} not found"
        end
      end

      sql = Query::TimestampLiterals.normalize(rewritten.sql, timestamp_columns(rewritten.tables))
      # The statement SQLite actually runs. When a query comes back empty and
      # the Timestream original looks right, this is the line that says why.
      Log.event("sqlite", sql: sql, binds: (binds.join(", ") unless binds.empty?))
      columns, rows = @store.execute_sql(sql, binds)
      [columns, rows, resolve_types(columns, rows, rewritten.tables)]
    end

    # `time` is a timestamp in every Timestream table; TIMESTAMP measures are
    # picked up from the catalog.
    def timestamp_columns(tables)
      tables.each_with_object(["time"]) do |(database_name, table_name), acc|
        @store.column_types(database_name, table_name).each do |name, ts_type|
          acc << name if ts_type == "TIMESTAMP"
        end
      end.uniq
    end

    # Declared catalog types win; anything computed is inferred from its values.
    # A TIMESERIES column is detected first: create_time_series() may be aliased
    # to the name of a real column, and the alias must not inherit that column's
    # scalar type.
    def resolve_types(columns, rows, tables)
      declared = tables.each_with_object({}) do |(database_name, table_name), acc|
        acc.merge!(@store.column_types(database_name, table_name))
      end

      columns.each_with_object({}).with_index do |(name, acc), index|
        acc[name] = time_series_type(rows, index) || scalar_type(declared[name], sample(rows, index))
      end
    end

    # A computed expression aliased to a real column's name must not inherit that
    # column's type -- `to_iso8601(time) AS time` is a VARCHAR, not a TIMESTAMP.
    # The catalog wins only where the values are actually consistent with it,
    # which is what distinguishes the stored column from an expression wearing
    # its name.
    def scalar_type(declared, value)
      return declared || "UNKNOWN" if value.nil?
      return Types.infer_type(value) if declared.nil?

      Types.consistent?(declared, value) ? declared : Types.infer_type(value)
    end

    def sample(rows, index)
      rows.each { |row| return row[index] unless row[index].nil? }
      nil
    end

    def infer_column_type(rows, index)
      value = sample(rows, index)
      value.nil? ? "UNKNOWN" : Types.infer_type(value)
    end

    # The element type comes from the first non-null point anywhere in the
    # column, since any one row's series may be empty or all-null.
    def time_series_type(rows, index)
      encoded = rows.map { |row| row[index] }.select { |value| Query::TimeSeries.encoded?(value) }
      return nil if encoded.empty?

      point = encoded.lazy.flat_map { |value| Query::TimeSeries.decode(value) }
                     .map(&:last).find { |value| !value.nil? }
      { time_series: point.nil? ? "UNKNOWN" : Types.infer_type(point) }
    end

    def column_type(type)
      return { "ScalarType" => type } unless type.is_a?(Hash)

      { "TimeSeriesMeasureValueColumnInfo" => { "Type" => { "ScalarType" => type[:time_series] } } }
    end

    def serialize_row(row, columns, types)
      data = columns.each_with_index.map do |name, index|
        type = types[name]
        value = row[index]
        if type.is_a?(Hash)
          serialize_time_series(value, type[:time_series])
        elsif value.nil?
          { "NullValue" => true }
        else
          { "ScalarValue" => Types.format_scalar(value, type) }
        end
      end
      { "Data" => data }
    end

    def serialize_time_series(value, scalar_type)
      return { "NullValue" => true } unless Query::TimeSeries.encoded?(value)

      points = Query::TimeSeries.decode(value).map do |time, point|
        datum = point.nil? ? { "NullValue" => true } : { "ScalarValue" => Types.format_scalar(point, scalar_type) }
        { "Time" => time, "Value" => datum }
      end
      { "TimeSeriesValue" => points }
    end

    def paginate(rows, offset, max_rows)
      return [rows, nil] if max_rows.nil?

      page = rows[offset, max_rows] || []
      next_offset = offset + page.size
      [page, next_offset < rows.size ? next_offset : nil]
    end

    def validate_max_rows(max_rows)
      return nil if max_rows.nil?

      max_rows = Integer(max_rows)
      unless max_rows.between?(1, MAX_ROWS_LIMIT)
        raise ValidationException, "MaxRows must be between 1 and #{MAX_ROWS_LIMIT}"
      end

      max_rows
    end

    def encode_token(query_string, offset)
      Base64.urlsafe_encode64(JSON.dump("q" => digest(query_string), "o" => offset))
    end

    def decode_token(token, query_string)
      return 0 if token.nil? || token.empty?

      payload = JSON.parse(Base64.urlsafe_decode64(token))
      raise ValidationException, "Invalid pagination token" unless payload["q"] == digest(query_string)

      Integer(payload["o"])
    rescue ArgumentError, JSON::ParserError
      raise ValidationException, "Invalid pagination token"
    end

    def digest(query_string)
      Digest::SHA256.hexdigest(query_string.strip)
    end

    # ------------------------------------------------------- meta statements

    def show_databases
      rows = @store.list_databases.map { |database| [database["DatabaseName"]] }
      [["Database"], rows, { "Database" => "VARCHAR" }]
    end

    def show_tables(database_name)
      name = unquote(database_name)
      rows = @store.list_tables(name).map { |table| [table["TableName"]] }
      [["Table"], rows, { "Table" => "VARCHAR" }]
    end

    def show_measures(reference)
      database_name, table_name = split_reference(reference)
      rows = @store.measure_schema(database_name, table_name).map do |measure|
        [measure["measure_name"], measure["data_type"], JSON.dump(
          measure["dimensions"].map { |dimension| { "data_type" => "varchar", "dimension_name" => dimension } }
        )]
      end
      [%w[measure_name data_type dimensions], rows,
       { "measure_name" => "VARCHAR", "data_type" => "VARCHAR", "dimensions" => "VARCHAR" }]
    end

    def describe(reference)
      database_name, table_name = split_reference(reference)
      raise ResourceNotFoundException, "The table #{table_name} does not exist." unless
        @store.table_exists?(database_name, table_name)

      rows = @store.describe_columns(database_name, table_name).map do |column|
        [column["column_name"], column["ts_type"].downcase, column["attribute_type"]]
      end
      [["Column", "Type", "Timestream attribute type"], rows,
       { "Column" => "VARCHAR", "Type" => "VARCHAR", "Timestream attribute type" => "VARCHAR" }]
    end

    def split_reference(reference)
      parts = unquote(reference).split(".")
      raise ValidationException, "Expected a database.table reference, got #{reference}" unless parts.size == 2

      parts
    end

    def unquote(value)
      value.gsub('"', "")
    end
  end
end
