# Changelog

Notable changes, newest first. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning follows [semver](https://semver.org/spec/v2.0.0.html).

Anything user-visible — a feature, a fix, a behaviour change — gets an entry under
**Unreleased** when it lands, not when it ships. Releasing moves that section under
a version heading; see [Releasing](README.md#releasing).

## [Unreleased]

## [1.3.0] - 2026-08-30

### Added

- The startup banner prints the browser's URL, with `0.0.0.0` shown as
  `localhost` so it can be followed, or says the browser is disabled.
- The browser's header says `timestream-local is online`, so opening the
  server's address answers the question it is usually opened to answer.

### Changed

- Metering fields carry approximations instead of zeros: `CumulativeBytesScanned`
  and `CumulativeBytesMetered` on a query, `BytesMetered` and `DataWrites` on a
  scheduled-query run, and `total_bytes_scanned` in an UNLOAD manifest. Values
  are charged at the size they occupy here plus a per-row overhead, and the
  metered figure keeps the real service's 10 MB floor. An aggregate under-reports,
  since only the rows it returned are counted — see [Metering](README.md#metering).
- A scheduled run's `DataWrites` is now approximate bytes written rather than a
  copy of `RecordsIngested`, which is what the field means in the real service.
  A consumer asserting `data_writes == records_ingested` will see them differ.

## [1.2.0] - 2026-08-30

### Added

- The browser at `GET /` lists registered scheduled queries with the status of
  their last run, and shows one in detail: schedule, target table, query text,
  and what the last run returned, ingested or failed with.
- Verbose logging on stdout, off by default: `bin/timestream-local --verbose` or
  `TIMESTREAM_LOCAL_VERBOSE=true`. One line per request, one per scheduled-query
  run, and the rewritten SQL each query really ran — which is what to read when a
  query comes back with fewer rows than it should.

## [1.1.0] - 2026-08-30

### Added

- A read-only browser at `GET /`: databases, their tables and columns, and a
  query box. Reads through the same query path clients use, so column types and
  TIMESERIES values render as an SDK would see them. No authentication, matching
  the rest of the server — set `TIMESTREAM_LOCAL_UI=false` to turn it off.

## [1.0.1] - 2026-08-30

### Changed

- Test fixtures and documentation use generic names throughout.
- README version references are derived from the `VERSION` constant rather than
  written out, and the release workflow reads that constant without loading the
  library — a mismatch between the two had failed the first release run.

## [1.0.0] - 2026-08-30

First public release. A local stand-in compatible with Amazon Timestream for
LiveAnalytics, speaking the real wire protocol so an AWS SDK talks to it with
nothing changed but the endpoint.

### Added

- **Write API** — databases and tables, single- and multi-measure `WriteRecords`,
  `CommonAttributes`, all four `TimeUnit` values, and Timestream's versioned
  upsert semantics including `RejectedRecordsException` with `ExistingVersion`.
  Columns are created on write, as the real service does.
- **Query API** — `Query` with `MaxRows`/`NextToken` pagination, `PrepareQuery`,
  `CancelQuery`, and `SHOW`/`DESCRIBE` answered from the catalog.
- **Trino-flavoured functions** — `ago`, `bin`, `date_trunc`, `date_add`,
  `date_diff`, the `from_`/`to_` conversions, `to_iso8601`, `if`, `count_if`,
  `max_by`, `min_by`, `xxhash64`, `to_base64`, `from_base64`, and
  `create_time_series` with the TIMESERIES wire shape.
- **Scheduled queries** — create, delete, describe, list and execute. No
  scheduler: runs happen only on `ExecuteScheduledQuery`, binding
  `@scheduled_runtime`, writing results into the configured target table, and
  posting an SNS-shaped completion callback asynchronously.
- **`UNLOAD`** to S3-compatible storage, writing CSV plus a manifest and
  returning the `rows`/`metadataFile`/`manifestFile` summary. Unsupported until
  `TIMESTREAM_LOCAL_S3_ENDPOINT` is set, rather than silently writing nowhere.
- Multi-architecture image published to GitHub Container Registry, built frozen
  against the committed lockfile so a rebuilt tag installs the same gems.

### Fixed

Every one of these returned a plausible wrong answer rather than an error, which
is the failure mode this project has to design against.

- `CAST(x AS varbinary)` fell through SQLite's affinity rules to NUMERIC and
  evaluated to `0`, so every hash was the hash of `"0"`. Also `CAST(x AS
  TIMESTAMP)` evaluating to `2026` and `CAST('true' AS BOOLEAN)` to `0`.
- `time + 1m` had the timestamp coerced to a number, yielding arithmetic
  nonsense without raising.
- Unresolvable double-quoted identifiers were silently reinterpreted as string
  literals by SQLite's legacy rule, so joins on them were quietly always false.
  Identifiers are now backtick-quoted, which has no such fallback, and a table
  written `db.table` is aliased to its bare name so `"table"."column"` resolves.
- Interval-shaped text *inside* an identifier was read as arithmetic: a table
  named `…-41830d` became `date_add_ns(…, -…)` and failed to resolve. Identifiers
  are now masked to opaque terms before any expression rule runs.
- Timestamp literals were compared as text against fixed-width stored values, so
  `<=` excluded the boundary row and `=` matched nothing while `>=` worked.
- `LIKE` folded ASCII case, unlike Trino.
- A result column took its type from the catalog even when the values could not
  have come from that column, so `to_iso8601(time) AS time` reported as
  `TIMESTAMP`.

[Unreleased]: https://github.com/wagner/timestream-local/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/wagner/timestream-local/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/wagner/timestream-local/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/wagner/timestream-local/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/wagner/timestream-local/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/wagner/timestream-local/releases/tag/v1.0.0
