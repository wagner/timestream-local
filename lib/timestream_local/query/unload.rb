# frozen_string_literal: true

require "json"
require "securerandom"
require "zlib"

module TimestreamLocal
  module Query
    # UNLOAD (<query>) TO '<s3 url>' WITH (<options>)
    #
    # Runs the inner query, writes its rows to object storage as CSV, and returns
    # a single summary row -- `rows`, `metadataFile`, `manifestFile` -- which is
    # all the caller sees. The rows themselves never come back over the wire; the
    # caller reads the manifest, then the files it names.
    #
    # An empty result is a normal outcome, not an error: `rows` comes back as 0
    # with a manifest listing no files.
    class Unload
      COLUMNS = %w[rows metadataFile manifestFile].freeze
      COLUMN_TYPES = { "rows" => "BIGINT", "metadataFile" => "VARCHAR", "manifestFile" => "VARCHAR" }.freeze

      DEFAULTS = {
        "format" => "CSV", "compression" => "GZIP", "field_delimiter" => ",",
        "escaped_by" => "\\", "include_header" => "true"
      }.freeze

      QUOTE = '"'
      UNLOAD_RE = /\Aunload\s*\(/i

      Statement = Struct.new(:query, :bucket, :prefix, :options, keyword_init: true)

      def self.statement?(sql)
        sql.match?(UNLOAD_RE)
      end

      # Hand-scanned rather than pattern-matched: the inner query contains its own
      # parentheses and string literals, so the closing paren has to be found by
      # counting depth while skipping quoted text.
      def self.parse(sql)
        body_start = sql.index("(") + 1
        body_end = matching_paren(sql, body_start)
        raise ValidationException, "UNLOAD is missing its closing parenthesis" if body_end.nil?

        query = sql[body_start...body_end]
        rest = sql[(body_end + 1)..].to_s

        destination = rest[/\A\s*to\s*'([^']*)'/i, 1] or
          raise ValidationException, "UNLOAD requires TO '<s3 url>'"
        bucket, prefix = split_destination(destination)

        Statement.new(query: query, bucket: bucket, prefix: prefix,
                      options: DEFAULTS.merge(parse_options(rest)))
      end

      def self.matching_paren(sql, start)
        depth = 1
        index = start
        while index < sql.length
          case sql[index]
          when "'", '"'
            quote = sql[index]
            index += 1
            index += 1 while index < sql.length && sql[index] != quote
          when "(" then depth += 1
          when ")"
            depth -= 1
            return index if depth.zero?
          end
          index += 1
        end
        nil
      end

      def self.split_destination(destination)
        unless destination.start_with?("s3://")
          raise ValidationException, "UNLOAD destination must be an s3:// URL, got #{destination.inspect}"
        end

        bucket, _, prefix = destination.delete_prefix("s3://").partition("/")
        raise ValidationException, "UNLOAD destination is missing a bucket" if bucket.empty?

        [bucket, prefix.chomp("/")]
      end

      def self.parse_options(rest)
        clause = rest[/\bwith\s*\((.*)\)\s*\z/im, 1] or return {}

        clause.scan(/(\w+)\s*=\s*'((?:[^']|'')*)'/).to_h do |key, value|
          [key.downcase, value.gsub("''", "'")]
        end
      end

      def initialize(statement, store: nil)
        @statement = statement
        @options = statement.options
        @store = store
      end

      def call(columns, rows, types)
        validate_options!
        store = @store || ObjectStore.build
        query_id = SecureRandom.uuid
        base = [@statement.prefix, query_id].reject { |part| part.nil? || part.empty? }.join("/")

        files = write_results(store, base, columns, rows, types)
        metadata = store.put(@statement.bucket, "#{base}/metadata.json",
                             JSON.pretty_generate(metadata_document(columns, types)),
                             content_type: "application/json")
        manifest = store.put(@statement.bucket, "#{base}/manifest.json",
                             JSON.pretty_generate(manifest_document(files)),
                             content_type: "application/json")

        [COLUMNS, [[rows.size, metadata, manifest]], COLUMN_TYPES]
      end

      private

      def validate_options!
        format = @options["format"].to_s.upcase
        raise ValidationException, "UNLOAD format #{format} is not supported; only CSV is." unless format == "CSV"

        compression = @options["compression"].to_s.upcase
        return if %w[NONE GZIP].include?(compression)

        raise ValidationException, "UNLOAD compression #{compression} is not supported; use NONE or GZIP."
      end

      # A single result file is written. Real Timestream may split across several,
      # which is why the manifest is a list -- a reader that follows it works
      # either way.
      def write_results(store, base, columns, rows, types)
        return [] if rows.empty?

        body = csv_body(columns, rows, types)
        gzip = @options["compression"].to_s.upcase == "GZIP"
        key = "#{base}/results/#{SecureRandom.hex(8)}.csv#{gzip ? '.gz' : ''}"
        payload = gzip ? gzip(body) : body

        url = store.put(@statement.bucket, key, payload,
                        content_type: gzip ? "application/gzip" : "text/csv")
        [{ url: url, rows: rows.size, bytes: payload.bytesize }]
      end

      def csv_body(columns, rows, types)
        lines = []
        lines << columns.map { |name| field(name) }.join(delimiter) if truthy?(@options["include_header"])
        rows.each do |row|
          lines << columns.each_with_index.map { |name, index|
            field(Types.format_scalar(row[index], types[name]))
          }.join(delimiter)
        end
        lines.empty? ? "" : "#{lines.join("\n")}\n"
      end

      # NULL is written as an empty, unquoted field. Anything containing the
      # delimiter, a quote or a newline is quoted, and the escape character is
      # applied inside.
      def field(value)
        return "" if value.nil?

        text = value.to_s
        return text unless text.include?(delimiter) || text.include?(QUOTE) || text.match?(/[\r\n]/)

        "#{QUOTE}#{escape(text)}#{QUOTE}"
      end

      def escape(text)
        return text.gsub(QUOTE, QUOTE * 2) if escape_character == QUOTE

        text.gsub(escape_character, escape_character * 2).gsub(QUOTE, "#{escape_character}#{QUOTE}")
      end

      def delimiter
        @options["field_delimiter"].to_s.empty? ? "," : @options["field_delimiter"]
      end

      def escape_character
        @options["escaped_by"].to_s.empty? ? "\\" : @options["escaped_by"]
      end

      def truthy?(value)
        %w[true 1 yes].include?(value.to_s.downcase)
      end

      def gzip(body)
        io = StringIO.new(+"", "wb")
        writer = Zlib::GzipWriter.new(io)
        writer.write(body)
        writer.close
        io.string
      end

      def manifest_document(files)
        {
          "result_files" => files.map do |file|
            {
              "url" => file[:url],
              "file_metadata" => { "content_length_in_bytes" => file[:bytes], "row_count" => file[:rows] }
            }
          end,
          "query_metadata" => {
            "content_length_in_bytes" => files.sum { |file| file[:bytes] },
            "total_bytes_scanned" => 0,
            "result_format" => "CSV"
          },
          "author" => { "name" => "timestream-local", "manifest_file_version" => "1.0" }
        }
      end

      def metadata_document(columns, types)
        {
          "ColumnInfo" => columns.map { |name| { "Name" => name, "Type" => { "ScalarType" => types[name] } } }
        }
      end
    end
  end
end
