# timestream-local

An independent, unofficial local stand-in **compatible with Amazon Timestream for
LiveAnalytics**, for development and tests. It speaks the real wire protocol, so
the AWS SDK talks to it unmodified — you change the endpoint and nothing else.

Scope is deliberately small: create databases and tables, ingest records, query
them back. It is not feature complete and does not try to be.

## Using the published image

Published to GitHub Container Registry, and public — no login is needed to pull.

```sh
docker pull ghcr.io/wagner/timestream-local:1.3.0
```

In another app's `docker-compose.yml`:

```yaml
services:
  timestream:
    image: ghcr.io/wagner/timestream-local:1.3.0
    ports: ["8080:8080"]
    environment:
      TIMESTREAM_LOCAL_ADVERTISED_ENDPOINT: "http://localhost:8080"
      # Only if that app uses UNLOAD; see the UNLOAD section.
      TIMESTREAM_LOCAL_S3_ENDPOINT: "http://minio:9000"
```

Each release publishes three tags — the full version, the minor series and the
major series (`1.1.0`, `1.1`, `1`). Pin the full version anywhere reproducibility
matters; the two shorter tags move forward as releases are cut. Images are
published for `linux/amd64` and `linux/arm64`.

## Browsing what is in it

Open the server's address in a browser — `http://localhost:8080` — for a small
read-only view of the databases, their tables and columns, with a query box.
Results render through the same code path clients read over the wire, so column
types and TIMESERIES values look the way an SDK would see them.

Registered scheduled queries are listed below the databases, each with the status
of its last run. Opening one shows its schedule, the table it writes to, the query
itself and what the last run did — how many rows it returned, how many records it
ingested, and the failure reason when it failed.

There is no login, because the server does not authenticate anything else either.
That is fine on a laptop and wrong on a shared host: anyone who can reach the port
can read everything in it. Set `TIMESTREAM_LOCAL_UI=false` to turn it off, or do
not publish the port.

## Quick start

```sh
docker-compose up -d
curl http://localhost:8080/health   # => ok
```

Set `TIMESTREAM_LOCAL_PORT` if 8080 is taken:

```sh
TIMESTREAM_LOCAL_PORT=8081 docker-compose up -d
```

Data lives in a named volume and survives restarts. To start clean:

```sh
docker-compose down -v
```

## Pointing the Ruby SDK at it

```ruby
options = {
  endpoint: "http://localhost:8080",
  region: "us-east-1",
  credentials: Aws::Credentials.new("test", "test")
}

write = Aws::TimestreamWrite::Client.new(options)
query = Aws::TimestreamQuery::Client.new(options)

write.create_database(database_name: "devdb")
write.create_table(database_name: "devdb", table_name: "readings")

write.write_records(
  database_name: "devdb", table_name: "readings",
  records: [{
    dimensions: [{ name: "device_id", value: "sensor-1" }],
    measure_name: "temperature", measure_value: "35.5", measure_value_type: "DOUBLE",
    time: (Time.now.to_f * 1000).round.to_s
  }]
)

query.query(query_string: <<~SQL)
  SELECT device_id, measure_value::double AS temperature
  FROM "devdb"."readings"
  WHERE time > ago(1h)
SQL
```

Signatures are not verified, so the credentials only need to exist.

If `AWS_PROFILE` names an SSO profile, add `token_provider: nil` as well:

```ruby
options = { endpoint: "http://localhost:8080", region: "us-east-1",
            credentials: Aws::Credentials.new("test", "test"), token_provider: nil }
```

`:token_provider` is resolved by its own `Aws::TokenProviderChain`, independently
of `:credentials`, so an SSO profile still sends the client looking for a cached
SSO token and it fails with `InvalidSSOToken` before any request is made. Passing
`nil` short-circuits the chain.

### About endpoint discovery

Every Timestream operation except `DescribeEndpoints` is modelled
`endpointdiscovery: {required: true}`. Normally the SDK resolves a cell endpoint
first and **replaces the request URL** with it, which would route straight past a
local server.

In `aws-sdk-ruby` this is a non-issue: the discovery handler is only installed
when `config.regional_endpoint` is true, and `RegionalEndpoint#resolve_endpoint`
only sets that flag when no custom endpoint was configured. **Passing `endpoint:`
disables discovery entirely** — you do not need `endpoint_discovery: false`.
`test/endpoint_discovery_test.rb` asserts this against the running server rather
than taking it on trust.

`DescribeEndpoints` is implemented anyway, for other SDKs and for clients that
opt into discovery. It returns an address *with an explicit scheme*
(`http://localhost:8080`) because SDKs only prepend `https://` when the address
has none — keeping the scheme keeps those clients on plain HTTP. Set
`TIMESTREAM_LOCAL_ADVERTISED_ENDPOINT` when the address the client reaches is not
the address the container binds.

Other languages, for reference: JS v3 never implemented discovery, so a custom
`endpoint` just works. Go v2 needs `EndpointDiscovery: aws.EndpointDiscoveryDisabled`.
Java v2 needs `endpointDiscoveryEnabled(false)` alongside `endpointOverride`.

## What is implemented

**Write** — `CreateDatabase`, `DeleteDatabase`, `DescribeDatabase`, `ListDatabases`,
`UpdateDatabase`, `CreateTable`, `DeleteTable`, `DescribeTable`, `ListTables`,
`UpdateTable`, `WriteRecords`, `DescribeEndpoints`.

**Query** — `Query`, `CancelQuery`, `PrepareQuery`, `DescribeEndpoints`,
`CreateScheduledQuery`, `DeleteScheduledQuery`, `DescribeScheduledQuery`,
`ListScheduledQueries`, `ExecuteScheduledQuery`.

`WriteRecords` covers single-measure and multi-measure records, `CommonAttributes`
merging, all four `TimeUnit` values, and Timestream's versioned upsert semantics:
identity is (dimensions, measure name, time), a higher `Version` overwrites, and an
equal or lower one is rejected with `RejectedRecordsException` reporting
`ExistingVersion`. Valid records in a partially rejected batch are still ingested.

Columns are created on write, as Timestream does — new dimensions and measures
appear automatically, and `SELECT *` returns them in Timestream's order
(dimensions, `measure_name`, `time`, measures).

A consequence worth knowing when seeding: a measure that has never been written
does not exist, so naming it in a `SELECT` fails with `no such column` rather than
returning nulls. A record that omits a measure — including one omitted because its
value was nil — is indistinguishable from that measure not existing at all, until
a query names it.

## Query dialect

Timestream's dialect is Trino's; storage here is SQLite, so queries are rewritten
on the way in and the gaps are filled with UDFs.

Supported: `measure_value::double` and friends as addressable columns, `ago()`,
`bin()`, `date_trunc`, `date_add`, `date_diff`, `from_milliseconds`,
`from_unixtime`, `to_milliseconds`, `to_unixtime`, `year`/`month`/`day`/`hour`/
`minute`/`second`, `to_iso8601()`, `if()`, `count_if()`, `max_by()`, `min_by()`, `xxhash64()`,
`to_base64()`, `from_base64()`, `create_time_series()`, plus whatever SQLite
already provides (aggregates, `GROUP BY`, `JOIN`, CTEs, window functions).
`SHOW DATABASES`, `SHOW TABLES FROM db`, `SHOW MEASURES FROM db.table` and
`DESCRIBE db.table` are answered from the catalog.

Pagination works through `MaxRows` and `NextToken`; a token is bound to its query
string, as it is in the real service.

### Interval literals

`1h`, `30m` and friends are translated to nanoseconds, both as function arguments
(`bin(time, 1h)`, `ago(30m)`) and when added to a timestamp (`time + 1h`,
`@scheduled_runtime - 30s`). The second case is rewritten to a `date_add_ns()`
call rather than left as SQL arithmetic, because SQLite would otherwise coerce the
timestamp string to a number: `'2026-01-01 00:00:00.000000000' + 60000000000`
evaluates to `60000002026` without raising.

Since the rewriter is regular expressions rather than a parser, the left operand
of `+`/`-` is only recognised in the shapes that actually occur — a column, a bind
parameter, or a no-argument function call. An interval literal anywhere else is
rejected with a `ValidationException` rather than compiled into SQL that runs and
returns the wrong rows.

### Dimension hashing

`to_base64(xxhash64(cast(<varchar> AS varbinary)))` is byte-identical to Ruby's
`Base64.strict_encode64([XXhash.xxh64(s)].pack("Q>"))` — XXH64 with seed 0, packed
big-endian, standard base64 — so an application can compute the same key in Ruby
and look rows up by it.

`varbinary` is rewritten to `BLOB`. This matters more than it looks: SQLite has no
`varbinary`, and its type-affinity rules fall through to NUMERIC, so
`CAST('a' AS varbinary)` evaluates to the integer `0`. Left alone, the hash of
every row would be the hash of `"0"` — uniformly wrong, consistent, and returned
without an error. `xxhash64()` additionally refuses a non-binary argument for the
same reason.

### Identifiers

Identifiers are rewritten to backtick quoting before they reach SQLite, and a
table written `db.table` is aliased to its bare name so `"table"."column"`
resolves the way it does in Trino.

Both matter for the same reason. SQLite's legacy double-quoted-string rule means
a double-quoted identifier that fails to resolve is silently reinterpreted as a
string literal — `"events"."host"` becomes the string `'events.host'`, and every
comparison against it is quietly false rather than an error. A join written that
way returns rows with NULL on one side and no indication anything went wrong.
Backtick quoting has no such fallback, so an unresolvable identifier raises. The
rule cannot be switched off from Ruby: it needs `sqlite3_db_config`, which the
`sqlite3` gem does not expose.

Identifiers are also *terminals*: once table and column references are resolved,
nothing inside a quoted name is treated as an operator or a literal. Without that,
a table called `readings-PT1M-0f9c2a-41830d` has its `-41830d` read as "minus
41830 days" and fails to resolve — which reads as provisioning having gone wrong
rather than as a query bug, because the table plainly exists.

### Timestamp literals

A timestamp literal is padded to the stored width when it is compared against a
timestamp: `time <= '2026-03-22 17:06:00'` becomes
`time <= '2026-03-22 17:06:00.000000000'`. Without that the comparison is a text
comparison, and the shorter literal sorts *before* an equal instant — so `<=`
excludes the boundary row and `=` matches nothing, while `>=` happens to be
right. Every range's lower bound works and only the upper bound is wrong, which
is a hard failure to spot.

`2026-03-22` and `2026-03-22 17:06` are padded too, filling the missing
components before the fractional part. Only literals actually compared against a
timestamp are touched, so a VARCHAR dimension holding a date-shaped string still
compares as text.

### Casts

SQLite resolves an unrecognised cast type to NUMERIC rather than rejecting it, so
`CAST('a' AS varbinary)` is `0`, `CAST('2026-03-22 17:06:00' AS TIMESTAMP)` is
`2026`, and `CAST('true' AS BOOLEAN)` is `0`. `varbinary` becomes `BLOB`, and
TIMESTAMP and BOOLEAN casts are routed to functions that do the real conversion.
`CAST(... AS DATE)` has no unambiguous representation here and is rejected rather
than guessed at.

`LIKE` is made case sensitive (`PRAGMA case_sensitive_like`), as it is in Trino
and unlike SQLite's default.

**Not supported:** `interpolate_*()`, `UNNEST` over timeseries, `MixedMeasureMappings`
in a scheduled query's target, batch load, tagging. Anything else Trino has and
SQLite does not will fail as a `QueryExecutionException`.

## UNLOAD

```sql
UNLOAD (SELECT ...) TO 's3://bucket/prefix'
  WITH (format = 'CSV', compression = 'NONE', include_header = 'false')
```

Runs the inner query, writes its rows to object storage as CSV, and returns a
single summary row — `rows`, `metadataFile`, `manifestFile`. The rows themselves
never come back over the wire: the caller reads the manifest, then the result
files it names. An empty result is a normal outcome, returning `rows` of 0 and a
manifest listing no files, rather than an error.

Supported options are `format` (CSV only), `compression` (`NONE` or `GZIP`),
`field_delimiter`, `escaped_by` and `include_header`. A field containing the
delimiter, a quote or a newline is quoted; quotes inside are escaped with
`escaped_by` rather than doubled. NULL is written as an empty unquoted field.

**UNLOAD needs object storage, and is unsupported until it is configured** —
without `TIMESTREAM_LOCAL_S3_ENDPOINT` it raises saying so, rather than appearing
to succeed while writing nowhere. Point it at anything that speaks S3; nothing is
AWS-specific. `docker-compose.yml` includes a [minio](https://min.io) service for
this, and the bucket is created if it does not exist.

By default no endpoint is set, no credentials are held and nothing reaches the
network, so the server runs — and `rake test` passes — with no object storage at
all. The suite exercises UNLOAD against an in-process stub of the same protocol.

## Scheduled queries

`CreateScheduledQuery` registers a query; `ExecuteScheduledQuery` runs it. There
is no scheduler — `ScheduleExpression` is stored and echoed back but never
interpreted, so a run happens only when asked for.

`@scheduled_runtime` is bound to the `InvocationTime` of the run, as a real bound
parameter rather than substituted into the SQL. A run writes its results into
`TargetConfiguration.TimestreamConfiguration` using `TimeColumn`,
`DimensionMappings` and `MultiMeasureMappings`; result columns not named in the
mappings are dropped, and rows with a null time or null dimension are skipped.

Execution is asynchronous, as it is in the real service: `ExecuteScheduledQuery`
returns immediately and the run — including the completion callback — happens on
another thread. This is deliberate. A caller that persists its state before the
call and treats the callback as the completion signal would deadlock against a
synchronous implementation if it were single threaded, because the callback would
arrive before the call it belongs to had returned.

On completion the run POSTs an SNS-shaped envelope as `application/json` to
`TIMESTREAM_LOCAL_NOTIFICATION_URL`. A `SnsConfiguration.TopicArn` that is itself
an `http(s)` URL overrides that for its own query, so one server can route
different queries at different receivers. Nothing is signed — a real SNS envelope
carries an RSA signature over a certificate fetched from an `amazonaws.com` host,
which cannot be reproduced locally, so a receiver has to be willing to accept an
unverified callback in development.

```json
{ "Type": "Notification",
  "MessageAttributes": { "queryArn": { "Value": "<arn>" } },
  "Message": "{\"type\":\"MANUAL_TRIGGER_SUCCESS\",\"arn\":\"<arn>\",\"scheduledQueryRunSummary\":{...}}" }
```

`Message` is a JSON *string*, as SNS delivers it. `invocationEpochSecond` echoes
the `InvocationTime` that was passed in, unchanged, so a receiver matching runs on
that value recognises it. The failure path sends `MANUAL_TRIGGER_FAILURE` with no
run summary.

## Metering

`CumulativeBytesScanned`, `CumulativeBytesMetered`, the scheduled-query
`ExecutionStats`, and an UNLOAD manifest's `total_bytes_scanned` carry
approximations rather than zeros. There is no scan accounting in SQLite to take a
real figure from, so the model is: every value in a row is charged at the size it
occupies here, plus a fixed per-row overhead; the metered figure keeps the
floor a real query is charged (`Metering::MINIMUM_METERED_BYTES`, 10 MB), so a
cheap query is not free.

Two consequences, both worth knowing before asserting on the numbers:

- **An aggregate under-reports.** `count(*)` over a million rows scans all of
  them and returns one, and one row is what gets counted here.
- **They are a plausible shape, not a cost estimate.** Good for a consumer that
  reads, logs or asserts on the field; useless for predicting a bill.

What they buy over the zeros they replace is that the fields move: a wider result
meters more than a narrow one, more rows meter more than fewer, and paging does
not change what the query read — every page reports the whole scan, as the real
service does.

`WriteRecords` has no byte field in its response, so nothing is approximated
there; `RecordsIngested` is a real count. A scheduled run's `DataWrites` is bytes
written, and `RecordsIngested` the count of records — they are different fields
and no longer the same number.

## Deliberate differences from the real service

- Writes are immediately readable. Timestream is eventually consistent.
- Retention periods are stored and returned but never enforced; nothing expires.
- Everything counts as memory store — `RecordsIngested.magnetic_store` is always 0.
- No throttling and no quotas. Metering figures are approximated rather than
  metered — see [Metering](#metering).
- Requests are not authenticated.
- A result column's type comes from the catalog only when its values are
  consistent with it, so an expression aliased over a real column's name
  (`to_iso8601(time) AS time`) is typed from what it returns rather than from the
  column whose name it borrowed.
- A computed boolean comes back as `BIGINT` `1`/`0` rather than `BOOLEAN`
  `true`/`false`. SQLite has no boolean type, so an expression's type cannot be
  recovered from its value. Declared `BOOLEAN` measure columns are unaffected —
  their type comes from the catalog.
- `ORDER BY` puts NULLs first ascending and last descending; Trino does the
  opposite. Add an explicit `NULLS FIRST`/`NULLS LAST` where it matters.
- Scheduled queries are never run on a schedule, only by `ExecuteScheduledQuery`.
- A scheduled query's `ErrorReportConfiguration` is stored but nothing is written
  to S3; rows that cannot be written are skipped and counted out of
  `RecordsIngested`.

## Releasing

The version lives in `lib/timestream_local.rb`, and changes are logged under
`## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) as they land. Releasing moves
that section under a version heading.

Tagging is what publishes: the `release` workflow runs the suite, refuses to
continue if the tag and the `VERSION` constant disagree, then builds and pushes to
ghcr.io and smoke tests what it pushed.

```sh
# bump VERSION in lib/timestream_local.rb, commit, then tag it to match:
git tag "v$(ruby -e 'print File.read("lib/timestream_local.rb")[/VERSION = "([^"]+)"/, 1]')"
git push origin --tags
```

Builds are frozen against the committed `Gemfile.lock`, so rebuilding a tag
installs the same gem versions it did originally.

A release moves the `X.Y` and `X` tags onto the new version; pin the full version
anywhere that matters.

## Development

```sh
bundle install
bundle exec rake test          # boots the app in-process on an ephemeral port
```

The suite drives the real `Aws::TimestreamWrite::Client` and
`Aws::TimestreamQuery::Client` over HTTP. To run the same tests against the
container:

```sh
docker-compose up -d
bundle exec rake test_container
```

`GET /__operations` returns the RPCs the server has received and `DELETE` clears
the list — that endpoint is how the discovery tests prove no `DescribeEndpoints`
round trip happened.

To run outside Docker:

```sh
TIMESTREAM_LOCAL_DATA=./timestream.db bundle exec ruby bin/timestream-local
```

In VS Code that is the **Start timestream-local** task (Terminal → Run Task),
which runs the same command with `--verbose` in a dedicated terminal.

### Verbose logging

`--verbose` (or `TIMESTREAM_LOCAL_VERBOSE=true`, which is the one that works in a
container) narrates what the server is doing on stdout: one line per request with
the resource it touched and how long it took, one line per scheduled-query run,
and — the useful one — the SQL that SQLite actually ran for each query:

```
[timestream-local] 14:22:53.485 WriteRecords database=metrics table=cpu records=1 ms=2
[timestream-local] 14:22:53.486 sqlite sql="SELECT host, bin(time, 3600000000000) ..." binds="2026-08-30 17:22:53.000000000"
[timestream-local] 14:22:53.486 Query sql="SELECT * FROM \"metrics\".\"cpu\"" rows=1 ms=1
```

That rewritten statement is what to read when a query returns fewer rows than it
should: the Timestream original may be fine while the SQL it was translated into
is asking something else.

### Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `TIMESTREAM_LOCAL_HOST` | `0.0.0.0` | Bind address |
| `TIMESTREAM_LOCAL_PORT` | `8080` | Bind port |
| `TIMESTREAM_LOCAL_DATA` | `/data/timestream.db` | SQLite file; `:memory:` for ephemeral |
| `TIMESTREAM_LOCAL_ADVERTISED_ENDPOINT` | `http://localhost:$PORT` | Address returned by `DescribeEndpoints` |
| `TIMESTREAM_LOCAL_REGION` | `us-east-1` | Region used in generated ARNs |
| `TIMESTREAM_LOCAL_ACCOUNT_ID` | `000000000000` | Account used in generated ARNs |
| `TIMESTREAM_LOCAL_THREADS` | `8` | Puma thread ceiling |
| `TIMESTREAM_LOCAL_NOTIFICATION_URL` | none | Where scheduled-query completion callbacks are POSTed |
| `TIMESTREAM_LOCAL_LOG_REQUESTS` | `false` | Log every request when `true` |
| `TIMESTREAM_LOCAL_VERBOSE` | `false` | Narrate requests, rewritten SQL and scheduled-query runs on stdout |
| `TIMESTREAM_LOCAL_UI` | `true` | Serve the read-only browser at `/`; `false` disables it |
| `TIMESTREAM_LOCAL_S3_ENDPOINT` | none | S3-compatible endpoint for `UNLOAD`; unset disables it |
| `TIMESTREAM_LOCAL_S3_ACCESS_KEY_ID` | `minioadmin` | Object storage access key |
| `TIMESTREAM_LOCAL_S3_SECRET_ACCESS_KEY` | `minioadmin` | Object storage secret key |
| `TIMESTREAM_LOCAL_S3_REGION` | `us-east-1` | Object storage region |

## How it works

One Rack app speaking AWS JSON 1.0, dispatching on `X-Amz-Target`. Write and Query
share the `Timestream_20181101` target prefix and their operation names do not
collide, so both services are served from a single port; `DescribeEndpoints` exists
in both but has an identical response shape, so the overlap is harmless.

Each Timestream table becomes two SQLite objects: a base table holding the data
plus `__id`/`__version` bookkeeping, and a view over it exposing exactly the
columns Timestream would expose, in Timestream's order. Queries run against the
view, so `SELECT *` never leaks internals. The view is rebuilt whenever a write
introduces a new column.

Timestamps are stored as fixed-width UTC text (`2021-12-01 19:00:00.000000000`).
That sorts lexicographically in the same order it sorts temporally, so range
predicates and `ORDER BY` work without a native timestamp type — and it is
byte-for-byte the format Timestream returns.

```
lib/timestream_local/
  server.rb            Rack app, target dispatch, error shaping
  store.rb             SQLite catalog, schema-on-write, versioned upserts
  write_api.rb         control plane + WriteRecords
  query_api.rb         Query, SHOW/DESCRIBE, pagination, result serialisation
  query/rewriter.rb    Timestream SQL -> SQLite
  query/functions.rb   ago/bin/date_* UDFs
  types.rb             wire <-> storage conversions
```

## Context

Timestream for LiveAnalytics closed to new customers on 20 June 2025 and is in
maintenance mode. This is useful if you already run it; if you are starting fresh,
AWS points at Timestream for InfluxDB instead.

## Trademarks

Amazon Web Services, AWS, and Amazon Timestream are trademarks of Amazon.com, Inc.
or its affiliates.

This is an independent project, developed for local development and testing. It is
not affiliated with, endorsed by, or sponsored by Amazon.com, Inc. or its
affiliates. It is not a distribution of, and not a substitute for, any Amazon Web
Services product, and it comes with no guarantee of fidelity to the behaviour of
the real service. Use it to develop against Timestream, not to decide how
Timestream behaves.

## License

MIT. See [LICENSE](LICENSE).
