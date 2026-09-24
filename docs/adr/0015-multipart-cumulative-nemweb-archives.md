# 0015. Multi-part NEMWEB archives are fetched in full and cumulative tables are scoped to their archive month

## Status

Accepted

## Context

`_get_archive` falls back to `NEMWEB_URL_ALT` when the primary `PUBLIC_DVD` URL 404s. AEMO
splits some months of some tables into numbered parts under that alternative pattern —
`PUBLIC_ARCHIVE#<TABLE>#FILE01#...zip`, `#FILE02#...`, `#FILE03#...` — and the next number past
the last part also 404s. `NEMWEB_URL_ALT` hardcoded `FILE01`, so every part past the first was
silently dropped: `_get_archive` returned on the first successful download and never checked
whether a `FILE02` existed.

`DISPATCH_FCAS_REQ_CONSTRAINT` is the table this was confirmed against directly: archive months
2025-08 through 2026-02 have 2 parts, 2026-03 through 2026-07 have 3. Beyond the missing parts,
AEMO's monthly archive for this table is **cumulative** — each month's file holds every row
since the table's 2024-12-09 introduction, sometimes running a week or more past the archive
month itself (the 2026-06 archive's rows run to 2026-07-08). Every cached monthly partition was
therefore an arbitrary ~39M-row slice of the same growing history, not that month's data, and
consecutive partitions duplicated most of each other's rows. `nempy`'s NEMWEB loader
(`historical_inputs/mms_db.py:475`) has the identical gap: it too requests only `FILE01` and
does not special-case a cumulative table.

Every other cached table was checked directly across its full archive history and confirmed to
publish a single, month-scoped part every month, so a fix scoped to this one table's known
failure mode risks nothing for the rest — but the multi-part *download* fix has to be generic,
since AEMO could split any table's archive in the future.

## Decision

- `NEMWEB_URL_ALT` takes a `{part:02d}` placeholder. `_get_archive` requests `FILE01`,
  `FILE02`, ... in order and keeps every part that downloads, stopping as soon as one part
  (after the first) 404s. A 404 on `FILE01` itself keeps today's behaviour: combined with the
  primary URL's own 404 into the existing "not published under either pattern" error. A
  transient failure on any part propagates immediately, exactly as it does today for the
  primary/`FILE01` pair — it is never mistaken for "no more parts". `_get_archive` returns
  `Vector{String}`; `_extract_d_lines` gained an overload for a vector of ZIP paths that
  concatenates each part's D-lines, in part order, into one combined CSV, reusing the
  single-ZIP method per part. Both `_extract_d_lines` methods delete their own temp CSV if
  they fail after creating it, not just on the happy path — confirmed necessary directly: a
  real multi-part `DISPATCH_FCAS_REQ_CONSTRAINT` re-populate hit a downstream disk limit and
  left a multi-gigabyte temp file behind before this was added.
- `_TABLE_SPECS` entries may carry an optional `month_filter_column`, read via
  `get(spec, :month_filter_column, nothing)` so every other entry is untouched.
  `DISPATCH_FCAS_REQ_CONSTRAINT` sets it to `"INTERVAL_DATETIME"`. When set,
  `_csv_to_parquet` keeps only rows whose parsed `month_filter_column` falls in `(first of
  archive month, first of next month]`, and — since a genuine duplicate row can now appear
  once per overlapping part — deduplicates on `sort_by` via `DISTINCT ON`, gated on the same
  field so it only ever runs for a table AEMO is known to publish cumulatively.
- **Boundary rule**: `INTERVAL_DATETIME` is the interval's *end*, not its start (the MMSDM
  convention). The interval ending exactly at `YYYY-MM-01 00:00:00` is the last interval of the
  *previous* month, not the first of the new one, so a month's window excludes its own opening
  instant and includes the next month's opening instant — `archive_month < t <= archive_month +
  1 month`.

## Consequences

- `DataSource` carries `month_filter_column`, threaded from `get_table`'s spec lookup through
  `_add_data` into `_csv_to_parquet`; every other call site keeps passing `nothing` implicitly.
- Existing `DISPATCH_FCAS_REQ_CONSTRAINT` partitions were written before this fix and must be
  re-populated with `force_new = true` to drop the duplicated, unscoped rows.
- A future table AEMO splits into parts is handled by the generic download loop with no code
  change; a future table AEMO publishes cumulatively needs its own `month_filter_column` entry
  the same way this one got it.
