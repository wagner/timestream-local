# frozen_string_literal: true

require "digest"
require "json"
require "sqlite3"

module TimestreamLocal
  # SQLite-backed catalog and storage.
  #
  # Layout, per Timestream table:
  #   "db.table$raw"  base table -- data columns plus __id / __version bookkeeping
  #   "db.table"      view over the base table exposing exactly the columns
  #                   Timestream would expose, in Timestream's order
  #                   (dimensions, measure_name, time, measures)
  #
  # Queries run against the view, so `SELECT *` returns the Timestream column
  # set rather than our internal bookkeeping. The view is rebuilt whenever a
  # write introduces a new dimension or measure, which is how the
  # schema-on-write behaviour of Timestream is reproduced.
  class Store
    RESERVED_COLUMNS = %w[time measure_name measure_value].freeze
    NAME_RE = /\A[a-zA-Z0-9_.\-]+\z/

    attr_reader :account_id, :region

    def initialize(path: ":memory:", region: "us-east-1", account_id: "000000000000")
      @region = region
      @account_id = account_id
      @mutex = Mutex.new
      @db = SQLite3::Database.new(path)
      @db.busy_timeout = 5_000
      @db.execute("PRAGMA journal_mode = WAL") unless path == ":memory:"
      @db.execute("PRAGMA foreign_keys = ON")
      # SQLite's LIKE folds ASCII case by default; Trino's does not.
      @db.execute("PRAGMA case_sensitive_like = ON")
      Query::Functions.install(@db)
      bootstrap!
    end

    def synchronize(&block)
      @mutex.owned? ? block.call : @mutex.synchronize(&block)
    end

    # ---------------------------------------------------------------- catalog

    def create_database(name, kms_key_id: nil)
      validate_name!(name, "DatabaseName")
      synchronize do
        raise ConflictException, "Database #{name} already exists" if database_row(name)

        now = Time.now.to_f
        @db.execute("INSERT INTO _databases VALUES (?, ?, ?, ?)", [name, kms_key_id, now, now])
        describe_database(name)
      end
    end

    def delete_database(name)
      synchronize do
        require_database!(name)
        raise ValidationException, "Database #{name} is not empty" if list_tables(name).any?

        @db.execute("DELETE FROM _databases WHERE name = ?", [name])
      end
    end

    def describe_database(name)
      synchronize do
        row = require_database!(name)
        {
          "Arn" => database_arn(name),
          "DatabaseName" => name,
          "TableCount" => list_tables(name).size,
          "KmsKeyId" => row["kms_key_id"],
          "CreationTime" => row["created_at"],
          "LastUpdatedTime" => row["updated_at"]
        }.compact
      end
    end

    def list_databases
      synchronize do
        @db.execute("SELECT name FROM _databases ORDER BY name").map { |r| describe_database(r[0]) }
      end
    end

    def create_table(database_name, table_name, retention: nil, magnetic: nil, schema: nil)
      validate_name!(table_name, "TableName")
      synchronize do
        require_database!(database_name)
        raise ConflictException, "Table #{table_name} already exists" if table_row(database_name, table_name)

        now = Time.now.to_f
        @db.execute(
          "INSERT INTO _tables VALUES (?, ?, ?, ?, ?, ?, ?)",
          [database_name, table_name, JSON.dump(retention || default_retention),
           JSON.dump(magnetic || {}), JSON.dump(schema || {}), now, now]
        )
        @db.execute(<<~SQL)
          CREATE TABLE #{quote_ident(raw_table(database_name, table_name))} (
            __id TEXT PRIMARY KEY,
            __version INTEGER NOT NULL DEFAULT 1,
            "time" TEXT NOT NULL,
            "measure_name" TEXT NOT NULL
          )
        SQL
        add_column_meta(database_name, table_name, "time", "TIMESTAMP", "system")
        add_column_meta(database_name, table_name, "measure_name", "VARCHAR", "system")
        rebuild_view(database_name, table_name)
        describe_table(database_name, table_name)
      end
    end

    def delete_table(database_name, table_name)
      synchronize do
        require_table!(database_name, table_name)
        @db.execute("DROP VIEW IF EXISTS #{quote_ident(view_table(database_name, table_name))}")
        @db.execute("DROP TABLE IF EXISTS #{quote_ident(raw_table(database_name, table_name))}")
        @db.execute("DELETE FROM _tables WHERE database_name = ? AND name = ?", [database_name, table_name])
        @db.execute("DELETE FROM _columns WHERE database_name = ? AND table_name = ?", [database_name, table_name])
        @db.execute("DELETE FROM _measures WHERE database_name = ? AND table_name = ?", [database_name, table_name])
      end
    end

    def describe_table(database_name, table_name)
      synchronize do
        row = require_table!(database_name, table_name)
        {
          "Arn" => table_arn(database_name, table_name),
          "TableName" => table_name,
          "DatabaseName" => database_name,
          "TableStatus" => "ACTIVE",
          "RetentionProperties" => JSON.parse(row["retention_json"]),
          "MagneticStoreWriteProperties" => JSON.parse(row["magnetic_json"]),
          "CreationTime" => row["created_at"],
          "LastUpdatedTime" => row["updated_at"]
        }
      end
    end

    def list_tables(database_name = nil)
      synchronize do
        rows =
          if database_name
            require_database!(database_name)
            @db.execute("SELECT database_name, name FROM _tables WHERE database_name = ? ORDER BY name",
                        [database_name])
          else
            @db.execute("SELECT database_name, name FROM _tables ORDER BY database_name, name")
          end
        rows.map { |db_name, name| describe_table(db_name, name) }
      end
    end

    def update_table(database_name, table_name, retention: nil, magnetic: nil)
      synchronize do
        row = require_table!(database_name, table_name)
        @db.execute(
          "UPDATE _tables SET retention_json = ?, magnetic_json = ?, updated_at = ? " \
          "WHERE database_name = ? AND name = ?",
          [JSON.dump(retention || JSON.parse(row["retention_json"])),
           JSON.dump(magnetic || JSON.parse(row["magnetic_json"])),
           Time.now.to_f, database_name, table_name]
        )
        describe_table(database_name, table_name)
      end
    end

    def update_database(database_name, kms_key_id)
      synchronize do
        require_database!(database_name)
        @db.execute("UPDATE _databases SET kms_key_id = ?, updated_at = ? WHERE name = ?",
                    [kms_key_id, Time.now.to_f, database_name])
        describe_database(database_name)
      end
    end

    # ----------------------------------------------------------------- writes

    # rows: array of hashes from WriteApi -- :id, :version, :time, :measure_name,
    # :columns ({name => [ts_type, value]}). Returns the count ingested; any
    # rejected records are yielded to the caller's collector.
    def write_rows(database_name, table_name, rows)
      synchronize do
        require_table!(database_name, table_name)
        rejected = []
        ingested = 0

        @db.transaction do
          rows.each_with_index do |row, index|
            record_index = row[:index] || index
            begin
              row[:columns].each { |name, (ts_type, _)| ensure_column(database_name, table_name, name, ts_type) }
              record_measure_schema(database_name, table_name, row[:measure_name], row[:measure_type])

              current = existing_version(database_name, table_name, row[:id])
              if upsert(database_name, table_name, row) == :rejected_version
                rejected << {
                  "RecordIndex" => record_index,
                  "Reason" => "The record version #{row[:version]} is not higher than the existing version " \
                              "#{current}. A higher version is required to update the measure value.",
                  "ExistingVersion" => current
                }
              else
                ingested += 1
              end
            rescue ApiError => e
              rejected << { "RecordIndex" => record_index, "Reason" => e.message }
            end
          end
        end

        [ingested, rejected]
      end
    end

    # ---------------------------------------------------------------- queries

    # `binds` are bound positionally. A named parameter repeated through a query
    # occupies a single slot, which is what lets @scheduled_runtime appear on
    # both sides of a window predicate and still be one value. The arity is
    # checked rather than left to SQLite, which would otherwise bind an
    # unsupplied parameter to NULL and quietly return no rows.
    def execute_sql(sql, binds = [])
      synchronize do
        statement = @db.prepare(sql)
        begin
          expected = statement.bind_parameter_count
          unless expected == binds.size
            raise QueryExecutionException,
                  "Query takes #{expected} bound parameter(s) but #{binds.size} were supplied. " \
                  "@scheduled_runtime is the only parameter supported."
          end

          result = binds.empty? ? statement.execute : statement.execute(*binds)
          columns = result.columns
          [columns, result.to_a]
        ensure
          statement.close
        end
      end
    rescue SQLite3::Exception => e
      raise QueryExecutionException, e.message
    end

    def column_types(database_name, table_name)
      synchronize do
        @db.execute("SELECT column_name, ts_type FROM _columns WHERE database_name = ? AND table_name = ?",
                    [database_name, table_name]).to_h
      end
    end

    def measure_schema(database_name, table_name)
      synchronize do
        require_table!(database_name, table_name)
        dimensions = @db.execute(
          "SELECT column_name FROM _columns WHERE database_name = ? AND table_name = ? AND kind = 'dimension' " \
          "ORDER BY rowid", [database_name, table_name]
        ).flatten
        @db.execute(
          "SELECT measure_name, data_type FROM _measures WHERE database_name = ? AND table_name = ? " \
          "ORDER BY measure_name", [database_name, table_name]
        ).map do |measure_name, data_type|
          { "measure_name" => measure_name, "data_type" => data_type, "dimensions" => dimensions }
        end
      end
    end

    # Column listing in the shape DESCRIBE returns: dimensions, measure_name,
    # time, then measures.
    def describe_columns(database_name, table_name)
      synchronize do
        require_table!(database_name, table_name)
        rows = typed_columns(database_name, table_name, "dimension").map do |name, ts_type|
          { "column_name" => name, "ts_type" => ts_type, "attribute_type" => "DIMENSION" }
        end
        rows << { "column_name" => "measure_name", "ts_type" => "VARCHAR", "attribute_type" => "MEASURE_NAME" }
        rows << { "column_name" => "time", "ts_type" => "TIMESTAMP", "attribute_type" => "TIMESTAMP" }
        rows + typed_columns(database_name, table_name, "measure").map do |name, ts_type|
          attribute = name.start_with?("measure_value::") ? "MEASURE_VALUE" : "MULTI"
          { "column_name" => name, "ts_type" => ts_type, "attribute_type" => attribute }
        end
      end
    end

    # ----------------------------------------------------- scheduled queries

    def create_scheduled_query(name, attributes)
      validate_name!(name, "Name")
      synchronize do
        arn = scheduled_query_arn(name)
        now = Time.now.to_f
        @db.execute(
          "INSERT INTO _scheduled_queries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [arn, name, attributes[:query_string], JSON.dump(attributes[:schedule] || {}),
           JSON.dump(attributes[:notification] || {}), JSON.dump(attributes[:target] || {}),
           JSON.dump(attributes[:error_report] || {}), attributes[:execution_role_arn],
           attributes[:kms_key_id], "ENABLED", now, now, nil]
        )
        arn
      end
    end

    def delete_scheduled_query(arn)
      synchronize do
        require_scheduled_query!(arn)
        @db.execute("DELETE FROM _scheduled_queries WHERE arn = ?", [arn])
      end
    end

    def scheduled_query(arn)
      synchronize { require_scheduled_query!(arn) }
    end

    def list_scheduled_queries
      synchronize do
        @db.execute("SELECT arn FROM _scheduled_queries ORDER BY name").flatten.map { |arn| scheduled_query_row(arn) }
      end
    end

    # The summary of the most recent run, surfaced by DescribeScheduledQuery as
    # LastRunSummary and used to answer PreviousInvocationTime.
    def record_scheduled_query_run(arn, summary)
      synchronize do
        @db.execute("UPDATE _scheduled_queries SET last_run_json = ?, updated_at = ? WHERE arn = ?",
                    [JSON.dump(summary), Time.now.to_f, arn])
      end
    end

    def scheduled_query_arn(name)
      "arn:aws:timestream:#{@region}:#{@account_id}:scheduled-query/#{name}-#{SecureRandom.hex(8)}"
    end

    def table_exists?(database_name, table_name)
      synchronize { !table_row(database_name, table_name).nil? }
    end

    def database_exists?(name)
      synchronize { !database_row(name).nil? }
    end

    def close
      @db.close unless @db.closed?
    end

    # --------------------------------------------------------------- internals

    def database_arn(name)
      "arn:aws:timestream:#{@region}:#{@account_id}:database/#{name}"
    end

    def table_arn(database_name, table_name)
      "#{database_arn(database_name)}/table/#{table_name}"
    end

    private

    def bootstrap!
      @db.execute_batch(<<~SQL)
        CREATE TABLE IF NOT EXISTS _databases (
          name TEXT PRIMARY KEY, kms_key_id TEXT, created_at REAL, updated_at REAL
        );
        CREATE TABLE IF NOT EXISTS _tables (
          database_name TEXT, name TEXT, retention_json TEXT, magnetic_json TEXT,
          schema_json TEXT, created_at REAL, updated_at REAL,
          PRIMARY KEY (database_name, name)
        );
        CREATE TABLE IF NOT EXISTS _columns (
          database_name TEXT, table_name TEXT, column_name TEXT, ts_type TEXT, kind TEXT,
          PRIMARY KEY (database_name, table_name, column_name)
        );
        CREATE TABLE IF NOT EXISTS _measures (
          database_name TEXT, table_name TEXT, measure_name TEXT, data_type TEXT,
          PRIMARY KEY (database_name, table_name, measure_name)
        );
        CREATE TABLE IF NOT EXISTS _scheduled_queries (
          arn TEXT PRIMARY KEY, name TEXT, query_string TEXT, schedule_json TEXT,
          notification_json TEXT, target_json TEXT, error_report_json TEXT,
          execution_role_arn TEXT, kms_key_id TEXT, state TEXT,
          created_at REAL, updated_at REAL, last_run_json TEXT
        );
      SQL
    end

    def default_retention
      { "MemoryStoreRetentionPeriodInHours" => 6, "MagneticStoreRetentionPeriodInDays" => 73 }
    end

    def database_row(name)
      row = @db.execute("SELECT name, kms_key_id, created_at, updated_at FROM _databases WHERE name = ?", [name]).first
      return nil unless row

      { "name" => row[0], "kms_key_id" => row[1], "created_at" => row[2], "updated_at" => row[3] }
    end

    def table_row(database_name, name)
      row = @db.execute(
        "SELECT retention_json, magnetic_json, schema_json, created_at, updated_at FROM _tables " \
        "WHERE database_name = ? AND name = ?", [database_name, name]
      ).first
      return nil unless row

      { "retention_json" => row[0], "magnetic_json" => row[1], "schema_json" => row[2],
        "created_at" => row[3], "updated_at" => row[4] }
    end

    def scheduled_query_row(arn)
      row = @db.execute(
        "SELECT arn, name, query_string, schedule_json, notification_json, target_json, error_report_json, " \
        "execution_role_arn, kms_key_id, state, created_at, updated_at, last_run_json " \
        "FROM _scheduled_queries WHERE arn = ?", [arn]
      ).first
      return nil unless row

      { "arn" => row[0], "name" => row[1], "query_string" => row[2],
        "schedule" => JSON.parse(row[3]), "notification" => JSON.parse(row[4]),
        "target" => JSON.parse(row[5]), "error_report" => JSON.parse(row[6]),
        "execution_role_arn" => row[7], "kms_key_id" => row[8], "state" => row[9],
        "created_at" => row[10], "updated_at" => row[11],
        "last_run" => row[12] && JSON.parse(row[12]) }
    end

    def require_scheduled_query!(arn)
      scheduled_query_row(arn) or
        raise ResourceNotFoundException, "The scheduled query #{arn} does not exist."
    end

    def require_database!(name)
      database_row(name) or raise ResourceNotFoundException, "The database #{name} does not exist."
    end

    def require_table!(database_name, table_name)
      require_database!(database_name)
      table_row(database_name, table_name) or
        raise ResourceNotFoundException, "The table #{table_name} does not exist."
    end

    def validate_name!(name, field)
      raise ValidationException, "#{field} must be provided" if name.nil? || name.empty?
      unless name.length.between?(3, 256)
        raise ValidationException, "#{field} must be between 3 and 256 characters"
      end
      raise ValidationException, "#{field} #{name.inspect} contains invalid characters" unless name.match?(NAME_RE)
    end

    # Dimension and measure names are allowed to be shorter than database and
    # table names.
    def validate_column_name!(name)
      raise ValidationException, "Name must be provided" if name.nil? || name.empty?
      raise ValidationException, "Name #{name.inspect} is too long" if name.length > 256
      raise ValidationException, "Name #{name.inspect} contains invalid characters" unless name.match?(NAME_RE)
    end

    def raw_table(database_name, table_name)
      "#{database_name}.#{table_name}$raw"
    end

    def view_table(database_name, table_name)
      "#{database_name}.#{table_name}"
    end

    def quote_ident(name)
      %("#{name.gsub('"', '""')}")
    end

    def add_column_meta(database_name, table_name, column, ts_type, kind)
      @db.execute("INSERT OR IGNORE INTO _columns VALUES (?, ?, ?, ?, ?)",
                  [database_name, table_name, column, ts_type, kind])
    end

    # `ts_type` arrives as VARCHAR_DIMENSION for dimensions so that the column's
    # role is known here; everything else is a measure.
    def ensure_column(database_name, table_name, column, ts_type)
      dimension = ts_type == "VARCHAR_DIMENSION"
      kind = dimension ? "dimension" : "measure"
      stored_type = dimension ? "VARCHAR" : ts_type

      existing = @db.execute(
        "SELECT ts_type, kind FROM _columns WHERE database_name = ? AND table_name = ? AND column_name = ?",
        [database_name, table_name, column]
      ).first
      if existing
        unless existing == [stored_type, kind]
          raise ValidationException,
                "Column #{column} already exists as #{existing[1]} of type #{existing[0]}, " \
                "cannot write #{kind} of type #{stored_type}"
        end
        return
      end

      # measure_value::<type> columns are synthesised by us, not user-supplied,
      # so they bypass the naming rules.
      unless column.start_with?("measure_value::")
        if RESERVED_COLUMNS.include?(column.downcase)
          raise ValidationException, "#{column} is a reserved column name"
        end

        validate_column_name!(column)
      end

      @db.execute(
        "ALTER TABLE #{quote_ident(raw_table(database_name, table_name))} " \
        "ADD COLUMN #{quote_ident(column)} #{Types.sqlite_decl(stored_type)}"
      )
      add_column_meta(database_name, table_name, column, stored_type, kind)
      rebuild_view(database_name, table_name)
    end

    # Timestream orders SELECT * as dimensions, measure_name, time, then measures.
    def rebuild_view(database_name, table_name)
      dimensions = ordered_columns(database_name, table_name, "dimension")
      measures = ordered_columns(database_name, table_name, "measure")
      columns = dimensions + %w[measure_name time] + measures
      select_list = columns.map { |c| quote_ident(c) }.join(", ")

      @db.execute("DROP VIEW IF EXISTS #{quote_ident(view_table(database_name, table_name))}")
      @db.execute(
        "CREATE VIEW #{quote_ident(view_table(database_name, table_name))} AS " \
        "SELECT #{select_list} FROM #{quote_ident(raw_table(database_name, table_name))}"
      )
    end

    def ordered_columns(database_name, table_name, kind)
      typed_columns(database_name, table_name, kind).map(&:first)
    end

    def typed_columns(database_name, table_name, kind)
      @db.execute(
        "SELECT column_name, ts_type FROM _columns WHERE database_name = ? AND table_name = ? AND kind = ? " \
        "ORDER BY rowid", [database_name, table_name, kind]
      )
    end

    def record_measure_schema(database_name, table_name, measure_name, measure_type)
      @db.execute("INSERT OR REPLACE INTO _measures VALUES (?, ?, ?, ?)",
                  [database_name, table_name, measure_name, measure_type.downcase])
    end

    def existing_version(database_name, table_name, id)
      @db.execute("SELECT __version FROM #{quote_ident(raw_table(database_name, table_name))} WHERE __id = ?",
                  [id]).dig(0, 0)
    end

    def upsert(database_name, table_name, row)
      raw = quote_ident(raw_table(database_name, table_name))
      current = existing_version(database_name, table_name, row[:id])

      if current.nil?
        columns = ["__id", "__version", "time", "measure_name"] + row[:columns].keys
        values = [row[:id], row[:version], row[:time], row[:measure_name]] +
                 row[:columns].values.map { |(_, value)| value }
        @db.execute(
          "INSERT INTO #{raw} (#{columns.map { |c| quote_ident(c) }.join(', ')}) " \
          "VALUES (#{Array.new(columns.size, '?').join(', ')})",
          values
        )
        return :inserted
      end

      return :rejected_version if row[:version] <= current

      assignments = ["__version = ?"] + row[:columns].keys.map { |c| "#{quote_ident(c)} = ?" }
      values = [row[:version]] + row[:columns].values.map { |(_, value)| value } + [row[:id]]
      @db.execute("UPDATE #{raw} SET #{assignments.join(', ')} WHERE __id = ?", values)
      :updated
    end
  end
end
