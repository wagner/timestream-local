# frozen_string_literal: true

require_relative "test_helper"

# SQLite has one integer type, so INTEGER vs BIGINT has to come from the SQL.
# A consumer that handled only BIGINT read Trino's INTEGER as nil in
# production while its suite, run here, saw BIGINT and stayed green.
class ColumnTypesTest < TimestreamTest
  AT = Time.utc(2026, 3, 22, 17, 6, 0)

  def seed(database_name, table_name)
    records = [%w[a 1], %w[a 2], %w[b 3]].each_with_index.map do |(host, card), index|
      {
        dimensions: [{ name: "host", value: host }, { name: "card", value: card }],
        measure_name: "payment", measure_value: (index + 1).to_s, measure_value_type: "BIGINT",
        time: millis(AT + index)
      }
    end
    write_client.write_records(database_name: database_name, table_name: table_name, records: records)
  end

  def types(response)
    response.column_info.to_h { |column| [column.name, column.type.scalar_type] }
  end

  def test_integer_literal_is_integer_through_union_all
    response = query_client.query(query_string: "SELECT 0 AS a, 'x' AS k UNION ALL SELECT 1, 'y'")

    assert_equal({ "a" => "INTEGER", "k" => "VARCHAR" }, types(response))
    assert_equal [%w[0 x], %w[1 y]], rows_as_hashes(response).map(&:values)
  end

  def test_union_widens_integer_beside_bigint
    response = query_client.query(query_string: "SELECT 0 AS a UNION ALL SELECT CAST(NULL AS BIGINT)")

    assert_equal({ "a" => "BIGINT" }, types(response))
  end

  def test_literal_beyond_32_bits_is_bigint
    response = query_client.query(query_string: "SELECT 2147483647 AS small, 2147483648 AS large, -5 AS negative")

    assert_equal({ "small" => "INTEGER", "large" => "BIGINT", "negative" => "INTEGER" }, types(response))
  end

  # The shape that crashed: the literal is chosen in a CTE, carried through a
  # self-union and a join, and only then selected.
  def test_integer_survives_ctes_and_joins
    with_table do |database_name, table_name|
      seed(database_name, table_name)
      table = %("#{database_name}"."#{table_name}")

      response = query_client.query(query_string: <<~SQL)
        WITH
        pairs AS (SELECT 0 AS a, host AS va, 1 AS b, card AS vb, COUNT(DISTINCT card) AS events
                  FROM #{table} GROUP BY host, card),
        sides AS (SELECT a AS d, va AS v, b AS o FROM pairs UNION ALL SELECT b, vb, a FROM pairs),
        degree AS (SELECT d, v, o, COUNT(*) AS partners FROM sides GROUP BY d, v, o)
        SELECT 'degree' AS kind, degree.d AS a, degree.o AS b, degree.partners AS n
          FROM degree JOIN pairs ON degree.v = pairs.va
        UNION ALL
        SELECT 'link', pairs.a, CAST(NULL AS BIGINT), pairs.events FROM pairs
      SQL

      assert_equal({ "kind" => "VARCHAR", "a" => "INTEGER", "b" => "BIGINT", "n" => "BIGINT" }, types(response))
      assert_equal %w[0], rows_as_hashes(response).map { |row| row["a"] }.uniq
    end
  end

  def test_aggregates_and_ranking_are_bigint
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query_client.query(query_string: <<~SQL)
        SELECT host, COUNT(*) AS n, SUM(1) AS total, MAX(1) AS one,
               ROW_NUMBER() OVER (ORDER BY host) AS r, RANK() OVER (ORDER BY host) AS rk,
               COUNT(*) OVER (PARTITION BY host) AS c
        FROM "#{database_name}"."#{table_name}" GROUP BY host
      SQL

      assert_equal({ "host" => "VARCHAR", "n" => "BIGINT", "total" => "BIGINT", "one" => "INTEGER",
                     "r" => "BIGINT", "rk" => "BIGINT", "c" => "BIGINT" }, types(response))
    end
  end

  def test_arithmetic_takes_the_wider_operand
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query_client.query(query_string: <<~SQL)
        SELECT 1 + 2 AS ints, measure_value::bigint + 1 AS mixed,
               CASE WHEN measure_value::bigint > 1 THEN 1 ELSE 0 END AS flag
        FROM "#{database_name}"."#{table_name}"
      SQL

      assert_equal({ "ints" => "INTEGER", "mixed" => "BIGINT", "flag" => "INTEGER" }, types(response))
    end
  end

  # SQLite returns comparisons as 0/1 and timestamps as text; Trino types them
  # BOOLEAN and, once cast, VARCHAR.
  def test_comparisons_are_boolean_and_casts_take_their_target
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query_client.query(query_string: <<~SQL)
        SELECT measure_value::bigint > 1 AS big, CAST(time AS VARCHAR) AS t
        FROM "#{database_name}"."#{table_name}" ORDER BY time
      SQL

      assert_equal({ "big" => "BOOLEAN", "t" => "VARCHAR" }, types(response))
      assert_equal %w[false true true], rows_as_hashes(response).map { |row| row["big"] }
    end
  end

  def test_empty_result_is_still_typed
    with_table do |database_name, table_name|
      seed(database_name, table_name)

      response = query_client.query(query_string: <<~SQL)
        SELECT 1 AS one, COUNT(*) OVER () AS n, CAST(NULL AS VARCHAR) AS v, NULL AS unknown
        FROM "#{database_name}"."#{table_name}" WHERE host = 'none'
      SQL

      assert_empty response.rows
      assert_equal({ "one" => "INTEGER", "n" => "BIGINT", "v" => "VARCHAR", "unknown" => "UNKNOWN" },
                   types(response))
    end
  end

  # A function the SQL reader does not know is typed from its values, as before.
  def test_unknown_function_falls_back_to_values
    response = query_client.query(query_string: "SELECT instr('abc', 'b') AS position, 7 AS seven")

    assert_equal({ "position" => "BIGINT", "seven" => "INTEGER" }, types(response))
  end
end
