# frozen_string_literal: true

require "cgi"

module TimestreamLocal
  # A small browser for whatever is in the store: databases, their tables, the
  # columns of each, and a query box.
  #
  # Read-only and unauthenticated, which is the same posture as the rest of the
  # server -- it does not verify signatures either. That is fine for a local
  # development tool and wrong for anything reachable by other people, so it can
  # be turned off with TIMESTREAM_LOCAL_UI=false.
  #
  # No JavaScript, no external assets, no template files. Every link is a plain
  # GET, so it works offline and in anything that renders HTML.
  class WebUi
    MAX_ROWS = 200
    PREVIEW_POINTS = 3

    class << self
      attr_writer :enabled

      def enabled?
        return @enabled if defined?(@enabled)

        ENV.fetch("TIMESTREAM_LOCAL_UI", "true") != "false"
      end
    end

    def initialize(store, query_api)
      @store = store
      @query_api = query_api
    end

    def call(env)
      params = parse_params(env["QUERY_STRING"].to_s)
      sql = params["q"].to_s.strip
      selected = params["db"].to_s

      html(page(selected, sql))
    rescue StandardError => e
      # The browser is never the reason the server falls over.
      html(page_shell("Error", %(<div class="error"><strong>#{h(e.class)}</strong> #{h(e.message)}</div>)), 500)
    end

    private

    # ------------------------------------------------------------------- pages

    def page(selected, sql)
      databases = @store.list_databases
      selected = databases.first["DatabaseName"] if selected.empty? && databases.any?

      page_shell("timestream-local", <<~HTML)
        <div class="layout">
          <aside>#{sidebar(databases, selected)}</aside>
          <main>
            #{query_form(sql)}
            #{sql.empty? ? welcome(databases) : results(sql)}
          </main>
        </div>
      HTML
    end

    def sidebar(databases, selected)
      return %(<p class="empty">No databases yet.</p>) if databases.empty?

      sections = databases.map do |database|
        name = database["DatabaseName"]
        open = name == selected
        tables = open ? table_list(name) : ""
        <<~HTML
          <div class="db#{open ? ' open' : ''}">
            <a class="db-name" href="#{h(link(db: name))}">#{h(name)}</a>
            <span class="count">#{database['TableCount']}</span>
            #{tables}
          </div>
        HTML
      end

      "<h2>Databases</h2>#{sections.join}"
    end

    def table_list(database_name)
      tables = @store.list_tables(database_name)
      return %(<p class="empty">No tables.</p>) if tables.empty?

      items = tables.map do |table|
        name = table["TableName"]
        <<~HTML
          <li>
            <a href="#{h(link(db: database_name, q: select_all(database_name, name)))}">#{h(name)}</a>
            <a class="schema" href="#{h(link(db: database_name, q: %(DESCRIBE "#{database_name}"."#{name}")))}"
               title="Show columns">schema</a>
          </li>
        HTML
      end
      "<ul class=\"tables\">#{items.join}</ul>"
    end

    def query_form(sql)
      <<~HTML
        <form method="get" class="query">
          <textarea name="q" rows="4" spellcheck="false"
                    placeholder="SELECT * FROM &quot;database&quot;.&quot;table&quot; WHERE time > ago(1h)">#{h(sql)}</textarea>
          <div class="actions">
            <button type="submit">Run query</button>
            <span class="hint">Read-only browser &mdash; results capped at #{MAX_ROWS} rows</span>
          </div>
        </form>
      HTML
    end

    def welcome(databases)
      return %(<p class="empty">Nothing here yet. Write some records and they will show up.</p>) if databases.empty?

      <<~HTML
        <p class="empty">Pick a table on the left, or write a query above.</p>
      HTML
    end

    def results(sql)
      response = @query_api.query("QueryString" => sql, "MaxRows" => MAX_ROWS)
      columns = response["ColumnInfo"]
      rows = response["Rows"]
      return %(<p class="empty">No rows.</p>#{truncation_note(response)}) if rows.empty?

      head = columns.map { |c| %(<th>#{h(c['Name'])}<span class="type">#{h(type_label(c['Type']))}</span></th>) }
      body = rows.map do |row|
        cells = row["Data"].each_with_index.map { |datum, i| "<td>#{cell(datum, columns[i])}</td>" }
        "<tr>#{cells.join}</tr>"
      end

      <<~HTML
        <div class="table-wrap">
          <table class="results">
            <thead><tr>#{head.join}</tr></thead>
            <tbody>#{body.join}</tbody>
          </table>
        </div>
        <p class="meta">#{rows.size} row#{'s' unless rows.size == 1}</p>
        #{truncation_note(response)}
      HTML
    rescue ApiError => e
      %(<div class="error"><strong>#{h(e.code)}</strong> #{h(e.message)}</div>)
    end

    def truncation_note(response)
      return "" unless response["NextToken"]

      %(<p class="meta">Showing the first #{MAX_ROWS} rows; add a LIMIT to narrow it.</p>)
    end

    # ------------------------------------------------------------------ values

    def cell(datum, column)
      return %(<span class="null">NULL</span>) if datum["NullValue"]
      return time_series(datum["TimeSeriesValue"]) if datum["TimeSeriesValue"]

      h(datum["ScalarValue"])
    end

    # A series can be long; show its shape and the first few points.
    def time_series(points)
      preview = points.first(PREVIEW_POINTS).map do |point|
        value = point.dig("Value", "ScalarValue") || "NULL"
        %(#{h(point['Time'])} &rarr; #{h(value)})
      end
      more = points.size > PREVIEW_POINTS ? %(<span class="more">and #{points.size - PREVIEW_POINTS} more</span>) : ""
      %(<div class="series"><span class="count">#{points.size} points</span>#{preview.map { |p|
        "<div>#{p}</div>"
      }.join}#{more}</div>)
    end

    def type_label(type)
      return type["ScalarType"] if type["ScalarType"]

      series = type["TimeSeriesMeasureValueColumnInfo"]
      series ? "TIMESERIES<#{series.dig('Type', 'ScalarType')}>" : "UNKNOWN"
    end

    # ------------------------------------------------------------------ plumbing

    def select_all(database_name, table_name)
      %(SELECT * FROM "#{database_name}"."#{table_name}" LIMIT 50)
    end

    def link(db: nil, q: nil)
      pairs = { "db" => db, "q" => q }.compact.reject { |_, v| v.to_s.empty? }
      pairs.empty? ? "/" : "/?#{pairs.map { |k, v| "#{k}=#{CGI.escape(v)}" }.join('&')}"
    end

    def parse_params(query_string)
      CGI.parse(query_string).transform_values(&:first)
    end

    def h(value)
      CGI.escapeHTML(value.to_s)
    end

    def html(body, status = 200)
      [status, { "content-type" => "text/html; charset=utf-8", "cache-control" => "no-store" }, [body]]
    end

    def page_shell(title, content)
      <<~HTML
        <!doctype html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{h(title)}</title>
        <style>#{STYLE}</style>
        </head><body>
        <header><a href="/">timestream-local</a> <span class="version">#{h(TimestreamLocal::VERSION)}</span></header>
        #{content}
        </body></html>
      HTML
    end

    STYLE = <<~CSS
      :root {
        --bg: #fbfbfa; --panel: #fff; --ink: #1a1a19; --muted: #6b6b68;
        --line: #e3e3e0; --accent: #2c5f4a; --error: #8c2f2f;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --bg: #16171a; --panel: #1d1f23; --ink: #e8e8e6; --muted: #9a9a96;
          --line: #2c2f35; --accent: #7fb99f; --error: #e08b8b;
        }
      }
      * { box-sizing: border-box; }
      body {
        margin: 0; background: var(--bg); color: var(--ink);
        font: 14px/1.5 ui-sans-serif, -apple-system, "Segoe UI", Roboto, sans-serif;
      }
      header {
        padding: 12px 20px; border-bottom: 1px solid var(--line);
        background: var(--panel); display: flex; align-items: baseline; gap: 8px;
      }
      header a { color: var(--ink); text-decoration: none; font-weight: 600; }
      .version { color: var(--muted); font-size: 12px; }
      .layout { display: flex; align-items: flex-start; gap: 20px; padding: 20px; }
      aside {
        flex: 0 0 240px; background: var(--panel); border: 1px solid var(--line);
        border-radius: 8px; padding: 12px; position: sticky; top: 20px;
      }
      aside h2 { font-size: 11px; text-transform: uppercase; letter-spacing: .08em;
        color: var(--muted); margin: 0 0 10px; }
      main { flex: 1; min-width: 0; }
      .db { margin-bottom: 6px; }
      .db-name { color: var(--ink); text-decoration: none; font-weight: 500; }
      .db.open > .db-name { color: var(--accent); }
      .db .count { color: var(--muted); font-size: 11px; margin-left: 6px; }
      ul.tables { list-style: none; margin: 6px 0 10px; padding-left: 10px;
        border-left: 1px solid var(--line); }
      ul.tables li { display: flex; justify-content: space-between; gap: 8px; padding: 2px 0; }
      ul.tables a { color: var(--ink); text-decoration: none; overflow-wrap: anywhere; }
      ul.tables a:hover { color: var(--accent); text-decoration: underline; }
      a.schema { color: var(--muted); font-size: 11px; flex: none; }
      form.query { margin-bottom: 16px; }
      textarea {
        width: 100%; padding: 10px; border: 1px solid var(--line); border-radius: 8px;
        background: var(--panel); color: var(--ink); resize: vertical;
        font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
      }
      .actions { display: flex; align-items: center; gap: 12px; margin-top: 8px; }
      button {
        background: var(--accent); color: var(--panel); border: 0; border-radius: 6px;
        padding: 7px 14px; font-size: 13px; font-weight: 500; cursor: pointer;
      }
      .hint, .meta, .empty { color: var(--muted); font-size: 12px; }
      .empty { padding: 20px 0; }
      .table-wrap { overflow-x: auto; border: 1px solid var(--line); border-radius: 8px;
        background: var(--panel); }
      table.results { border-collapse: collapse; width: 100%;
        font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; }
      table.results th, table.results td {
        text-align: left; padding: 7px 10px; border-bottom: 1px solid var(--line);
        white-space: nowrap; vertical-align: top;
      }
      table.results th { position: sticky; top: 0; background: var(--panel); }
      table.results tbody tr:last-child td { border-bottom: 0; }
      .type { display: block; font-size: 10px; font-weight: 400; color: var(--muted); }
      .null { color: var(--muted); font-style: italic; }
      .series .count { display: block; font-size: 10px; color: var(--muted); }
      .series .more { font-size: 11px; color: var(--muted); }
      .error {
        border: 1px solid var(--error); border-radius: 8px; padding: 12px;
        color: var(--error); background: var(--panel); overflow-wrap: anywhere;
      }
    CSS
  end
end
