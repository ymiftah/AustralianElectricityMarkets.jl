# 0019 Multi-part NEMWEB archives are fetched in full; cumulative tables are scoped to their archive month

## Status

Accepted

## What

- When the primary `PUBLIC_DVD` URL 404s, `_get_archive` fetches `FILE01`, `FILE02`, ... under `NEMWEB_URL_ALT` (a `{part:02d}` placeholder) and keeps every part, stopping when a part after the first 404s. A 404 on `FILE01` is the existing "not published under either pattern" error; a transient failure on any part propagates. It returns `Vector{String}`.
- AEMO's monthly archive of `DISPATCH_FCAS_REQ_CONSTRAINT` is cumulative (every row since 2024-12-09), so its `_TABLE_SPECS` entry sets `month_filter_column = "INTERVAL_DATETIME"` to scope each partition to its own month.

## How

- `_write_d_lines` streams one ZIP's D-lines into an `IO` and drops an out-of-month line before it reaches disk; `_extract_d_lines` has single-ZIP and `Vector{String}` methods that stream every part into one temp file, and delete the temp CSV on failure.
- The column's raw text is compared lexicographically with `_month_filter_bounds`' `"YYYY/MM/DD HH:MM:SS"` strings (NEMWEB zero-pads). `_csv_to_parquet`'s `WHERE`/`DISTINCT ON` remain a second check. `DataSource` carries `month_filter_column`.
- Boundary rule: `INTERVAL_DATETIME` is the interval end, so a month is `archive_month < t <= archive_month + 1 month`.

## Why

- Taking only `FILE01` silently dropped later parts, and a cumulative table cached as duplicated, unscoped slices.
- The full cumulative history is tens of gigabytes even as a temp CSV, so filtering has to happen while streaming.
- The download loop is generic because AEMO could split any table; the month filter is per table because every other table was checked and publishes one month-scoped part.
- Partitions written before the filter must be repopulated with `force_new = true`. A future cumulative table needs its own `month_filter_column`.
