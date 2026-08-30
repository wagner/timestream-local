# frozen_string_literal: true

require "securerandom"

require_relative "test_helper"

# Places where Trino has a type and SQLite has a permissive coercion. Each of
# these failed by returning a plausible wrong answer rather than an error, so
# the assertions are about values, not about not raising.
class QueryDialectTest < TimestreamTest
  AT = Time.utc(2026, 3, 22, 17, 6, 0)

  def seed(database_name, table_name)
    records = [%w[stripe merchant_a], %w[stripe merchant_b], %w[adyen merchant_c]].each_with_index.map do |row, index|
      provider, merchant = row
      {
        dimensions: [{ name: "provider", value: provider }, { name: "merchant_id", value: merchant }],
        measure_name: "payment", measure_value: "1", measure_value_type: "BIGINT",
        time: millis(AT + index)
      }
    end
    write_client.write_records(database_name: database_name, table_name: table_name, records: records)
  end

  def query(sql)
    rows_as_hashes(query_client.query(query_string: sql))
  end

  # ------------------------------------------- identifiers must not become strings

  # SQLite's legacy double-quoted-string fallback turns an unresolvable
  # identifier into a string literal. `"tbl"."provider"` became the string
  # 'tbl.provider' -- not an error, just a value that is never equal to anything.
  def test_bare_table_qualified_column_resolves_to_the_column
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      rows = query(<<~SQL)
        SELECT "#{table_name}"."provider" AS p
        FROM "#{database_name}"."#{table_name}"
        ORDER BY "#{table_name}"."provider"
      SQL

      assert_equal %w[adyen stripe stripe], rows.map { |row| row["p"] }
    end
  end

  def test_bare_table_qualified_column_in_a_predicate
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      rows = query(<<~SQL)
        SELECT provider FROM "#{database_name}"."#{table_name}"
        WHERE "#{table_name}"."provider" = 'stripe'
      SQL

      assert_equal 2, rows.size
    end
  end

  def test_database_qualified_column_resolves
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      rows = query(<<~SQL)
        SELECT count(*) AS n FROM "#{database_name}"."#{table_name}"
        WHERE "#{database_name}"."#{table_name}"."provider" = 'adyen'
      SQL

      assert_equal "1", rows.first["n"]
    end
  end

  # An identifier that resolves to nothing must fail loudly rather than
  # degrading into a string.
  def test_unresolvable_identifier_raises
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      error = assert_raises(Aws::TimestreamQuery::Errors::QueryExecutionException) do
        query(%(SELECT "no_such_column" FROM "#{database_name}"."#{table_name}"))
      end
      assert_match(/no such column/i, error.message)
    end
  end

  # The shape an ORM adapter generates for a grouped chart: rank groups in a CTE,
  # then join it back on the bare table name. The join silently never matched, so
  # the chart drew the right bars with every label null.
  def test_cte_joined_back_on_the_bare_table_name
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      rows = query(<<~SQL)
        WITH "top_groups" AS (
          SELECT "#{database_name}"."#{table_name}"."merchant_id" AS merchant_id,
                 ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, "#{database_name}"."#{table_name}"."merchant_id") AS seq
          FROM "#{database_name}"."#{table_name}"
          WHERE "#{database_name}"."#{table_name}"."merchant_id" IS NOT NULL
          GROUP BY "#{database_name}"."#{table_name}"."merchant_id"
        )
        SELECT IF(top_groups.seq > 2, 'others', CAST(top_groups.merchant_id AS VARCHAR)) AS label,
               count(*) AS n
        FROM "#{database_name}"."#{table_name}"
        LEFT JOIN top_groups ON top_groups.merchant_id = "#{table_name}"."merchant_id"
        GROUP BY IF(top_groups.seq > 2, 'others', CAST(top_groups.merchant_id AS VARCHAR))
        ORDER BY label
      SQL

      # Every label must be a real merchant, never nil from a join that missed.
      refute_includes rows.map { |row| row["label"] }, nil
      assert_equal %w[merchant_a merchant_b others], rows.map { |row| row["label"] }
      assert_equal %w[1 1 1], rows.map { |row| row["n"] }
    end
  end

  # ------------------------------------------------ identifiers are terminals

  # A quoted identifier is a terminal: nothing inside a name is an operator or a
  # literal. Table names here are `<prefix>-<interval>-<id>-<id>` where the ids
  # are the tail of a UUID, so a name ending `-20250d` is ordinary -- and was
  # being read as "minus 20250 days", producing `no such table` for a table that
  # exists. Hex ids make `d` reachable, so this was routine rather than exotic.
  INTERVAL_SHAPED_NAMES = %w[
    data_point-PT1M-346eea-20250d tbl-20250d tbl-5m tbl-1h tbl-7d tbl-3s
    tbl-5m-tail tbl-1d-2h tbl-5mx tbl-a5m tbl5m tbl-abc123 tbl-2026
  ].freeze

  def test_interval_shaped_identifiers_are_left_intact
    INTERVAL_SHAPED_NAMES.each do |name|
      rewritten = TimestreamLocal::Query::Rewriter.new(%(SELECT h FROM "metrics"."#{name}")).call.sql
      assert_includes rewritten, name, "#{name} was rewritten as an expression"
      refute_includes rewritten, "date_add_ns", "#{name} was read as interval arithmetic"
    end
  end

  # The name is only one axis. A reference to it can be bare, two-part or
  # three-part, with the column quoted or not, in SELECT, WHERE or ORDER BY --
  # and an ORM adapter emits three-part references throughout. Masking that
  # covered only some of those shapes left the common case broken.
  def test_every_reference_shape_to_an_interval_shaped_name_survives
    database = "metrics-acaf0c"
    table = "source-687f1b-44029d"
    from = %(FROM "#{database}"."#{table}")

    [
      %(SELECT id #{from}),
      %(SELECT "#{table}"."id" #{from}),
      %(SELECT "#{database}"."#{table}"."id" #{from}),
      %(SELECT id #{from} WHERE "#{table}"."measure_name" = 'm'),
      %(SELECT id #{from} WHERE "#{database}"."#{table}".measure_name = 'm'),
      %(SELECT id #{from} WHERE "#{database}"."#{table}"."measure_name" = 'm'),
      %(SELECT id #{from} ORDER BY "#{database}"."#{table}".time ASC),
      %(SELECT COUNT(*) #{from} GROUP BY "#{database}"."#{table}".measure_name)
    ].each do |sql|
      rewritten = TimestreamLocal::Query::Rewriter.new(sql).call.sql
      refute_includes rewritten, "date_add_ns", "interval arithmetic fired inside an identifier: #{sql}"
      assert_includes rewritten, table, "the table name did not survive: #{sql}"
    end
  end

  # Three-part references are the ORM's default, so they get an end-to-end pass
  # rather than only a rewriter-level one.
  def test_three_part_references_to_an_interval_shaped_name_execute
    database_name = "metrics-#{SecureRandom.hex(3)}"
    table_name = "source-687f1b-44029d"
    write_client.create_database(database_name: database_name)
    write_client.create_table(database_name: database_name, table_name: table_name)

    write_client.write_records(
      database_name: database_name, table_name: table_name,
      records: [{
        dimensions: [{ name: "external_id", value: "pay_1" }],
        measure_name: "m", measure_value: "1", measure_value_type: "BIGINT", time: millis(AT)
      }]
    )

    rows = query(<<~SQL)
      SELECT "#{database_name}"."#{table_name}"."external_id" AS id
      FROM "#{database_name}"."#{table_name}"
      WHERE "#{database_name}"."#{table_name}".measure_name = 'm'
      ORDER BY "#{database_name}"."#{table_name}".time ASC
    SQL

    assert_equal [{ "id" => "pay_1" }], rows
  ensure
    write_client.delete_table(database_name: database_name, table_name: table_name)
    write_client.delete_database(database_name: database_name)
  end

  def test_a_table_whose_name_ends_in_an_interval_is_queryable
    database_name = unique("db")
    # The real shape: prefix, interval, then two six-hex-character UUID tails.
    table_name = "data_point-PT1M-346eea-20250d"
    write_client.create_database(database_name: database_name)
    write_client.create_table(database_name: database_name, table_name: table_name)

    write_client.write_records(
      database_name: database_name, table_name: table_name,
      records: [{
        dimensions: [{ name: "h", value: "5xjR7l5pQOk=" }],
        measure_name: "m", measure_value: "6", measure_value_type: "BIGINT", time: millis(AT)
      }]
    )

    rows = query(%(SELECT h, measure_value::bigint AS a1 FROM "#{database_name}"."#{table_name}"))
    assert_equal [{ "h" => "5xjR7l5pQOk=", "a1" => "6" }], rows
  ensure
    write_client.delete_table(database_name: database_name, table_name: table_name)
    write_client.delete_database(database_name: database_name)
  end

  # The rule fired more than once in a single name, nesting as it went.
  def test_a_name_containing_two_intervals_is_left_intact
    database_name = unique("db")
    table_name = "rollup-1d-2h-ab12cd"
    write_client.create_database(database_name: database_name)
    write_client.create_table(database_name: database_name, table_name: table_name)

    write_client.write_records(
      database_name: database_name, table_name: table_name,
      records: [{
        dimensions: [{ name: "region-7d", value: "eu" }],
        measure_name: "m", measure_value: "1", measure_value_type: "BIGINT", time: millis(AT)
      }]
    )

    # The dimension name carries the same shape, so columns are covered too.
    rows = query(<<~SQL)
      SELECT "#{table_name}"."region-7d" AS r
      FROM "#{database_name}"."#{table_name}"
      WHERE "#{table_name}"."region-7d" = 'eu'
    SQL
    assert_equal [{ "r" => "eu" }], rows
  ensure
    write_client.delete_table(database_name: database_name, table_name: table_name)
    write_client.delete_database(database_name: database_name)
  end

  # Masking identifiers must not cost interval arithmetic on a quoted column.
  def test_interval_arithmetic_on_a_quoted_column_still_works
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      rows = query(<<~SQL)
        SELECT "time" + 1h AS later FROM "#{database_name}"."#{table_name}"
        WHERE "time" = '#{AT.strftime('%Y-%m-%d %H:%M:%S')}'
      SQL

      assert_equal "2026-03-22 18:06:00.000000000", rows.first["later"]
    end
  end

  # ------------------------------------------------- timestamp literal comparison

  # Stored timestamps are fixed width; a literal is not. Comparing them as text
  # made `<=` exclude the boundary row and `=` match nothing, while `>=` came out
  # right -- so every range's lower bound worked and only the upper bound was wrong.
  def test_whole_second_literal_compares_as_a_timestamp
    with_table do |database_name, table_name|
      seed(database_name, table_name)
      literal = AT.strftime("%Y-%m-%d %H:%M:%S")
      from = %(FROM "#{database_name}"."#{table_name}")

      assert_equal "1", query(%(SELECT count(*) AS n #{from} WHERE time = '#{literal}')).first["n"]
      assert_equal "1", query(%(SELECT count(*) AS n #{from} WHERE time <= '#{literal}')).first["n"]
      assert_equal "3", query(%(SELECT count(*) AS n #{from} WHERE time >= '#{literal}')).first["n"]
      assert_equal "0", query(%(SELECT count(*) AS n #{from} WHERE time < '#{literal}')).first["n"]
    end
  end

  def test_inclusive_range_keeps_its_final_bucket
    with_table do |database_name, table_name|
      seed(database_name, table_name)
      # Rows sit at AT, AT+1s and AT+2s; an inclusive upper bound must keep all three.
      rows = query(<<~SQL)
        SELECT count(*) AS n FROM "#{database_name}"."#{table_name}"
        WHERE time >= '#{AT.strftime('%Y-%m-%d %H:%M:%S')}'
          AND time <= '#{(AT + 2).strftime('%Y-%m-%d %H:%M:%S')}'
      SQL

      assert_equal "3", rows.first["n"]
    end
  end

  def test_between_covers_both_bounds
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      rows = query(<<~SQL)
        SELECT count(*) AS n FROM "#{database_name}"."#{table_name}"
        WHERE time BETWEEN '#{AT.strftime('%Y-%m-%d %H:%M:%S')}'
                       AND '#{(AT + 2).strftime('%Y-%m-%d %H:%M:%S')}'
      SQL

      assert_equal "3", rows.first["n"]
    end
  end

  # Minute-precision and date-only literals are legal timestamps too. Missing
  # components have to be filled before the fraction is padded, or '17:06' would
  # become '17:06:.000000'.
  def test_lower_precision_literals
    with_table do |database_name, table_name|
      seed(database_name, table_name)
      from = %(FROM "#{database_name}"."#{table_name}")

      assert_equal "3", query(%(SELECT count(*) AS n #{from} WHERE time >= '2026-03-22 17:06')).first["n"]
      assert_equal "3", query(%(SELECT count(*) AS n #{from} WHERE time >= '2026-03-22')).first["n"]
      assert_equal "0", query(%(SELECT count(*) AS n #{from} WHERE time < '2026-03-22 17:06')).first["n"]
    end
  end

  def test_literal_on_the_left_of_the_comparison
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      rows = query(<<~SQL)
        SELECT count(*) AS n FROM "#{database_name}"."#{table_name}"
        WHERE '#{AT.strftime('%Y-%m-%d %H:%M:%S')}' <= time
      SQL

      assert_equal "3", rows.first["n"]
    end
  end

  # ------------------------------------------------- casts to types SQLite lacks

  # SQLite has no TIMESTAMP affinity, so this cast fell through to NUMERIC and
  # evaluated to the integer 2026.
  def test_cast_to_timestamp_is_not_a_numeric_coercion
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query_client.query(query_string: <<~SQL)
        SELECT CAST('2026-03-22 17:06:00' AS TIMESTAMP) AS t
        FROM "#{database_name}"."#{table_name}" LIMIT 1
      SQL

      assert_equal "2026-03-22 17:06:00.000000000", rows_as_hashes(response).first["t"]
      assert_equal "TIMESTAMP", response.column_info.first.type.scalar_type
    end
  end

  # Likewise BOOLEAN: `CAST('true' AS BOOLEAN)` evaluated to 0, so a predicate
  # built on it was false for every row.
  def test_cast_to_boolean_is_not_a_numeric_coercion
    with_table do |database_name, table_name|
      seed(database_name, table_name)
      from = %(FROM "#{database_name}"."#{table_name}")

      assert_equal "3", query(%(SELECT count(*) AS n #{from} WHERE CAST('true' AS BOOLEAN))).first["n"]
      assert_equal "0", query(%(SELECT count(*) AS n #{from} WHERE CAST('false' AS BOOLEAN))).first["n"]
    end
  end

  def test_cast_to_date_is_rejected_rather_than_coerced
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      error = assert_raises(Aws::TimestreamQuery::Errors::ValidationException) do
        query(%(SELECT CAST(time AS DATE) AS d FROM "#{database_name}"."#{table_name}"))
      end
      assert_match(/AS DATE\) is not supported/, error.message)
    end
  end

  # SQLite folds ASCII case in LIKE by default; Trino does not.
  def test_like_is_case_sensitive
    with_table do |database_name, table_name|
      seed(database_name, table_name)
      from = %(FROM "#{database_name}"."#{table_name}")

      assert_equal "2", query(%(SELECT count(*) AS n #{from} WHERE provider LIKE 'stri%')).first["n"]
      assert_equal "0", query(%(SELECT count(*) AS n #{from} WHERE provider LIKE 'STRI%')).first["n"]
    end
  end

  # Only literals compared against a timestamp are padded. A VARCHAR dimension
  # holding a timestamp-shaped string still compares as text.
  def test_a_varchar_holding_a_timestamp_shaped_string_is_not_padded
    with_table do |database_name, table_name|
      write_client.write_records(
        database_name: database_name, table_name: table_name,
        records: [{
          dimensions: [{ name: "label", value: "2026-03-22 17:06:00" }],
          measure_name: "m", measure_value: "1", measure_value_type: "BIGINT",
          time: millis(AT)
        }]
      )

      rows = query(<<~SQL)
        SELECT count(*) AS n FROM "#{database_name}"."#{table_name}"
        WHERE label = '2026-03-22 17:06:00'
      SQL

      assert_equal "1", rows.first["n"]
    end
  end
end
