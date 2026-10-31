# 0050. Constraint definitions from pre-2015 monolithic archives

## Status

Accepted

## Context

`GENCONDATA` and the `SPD*CONSTRAINT` term tables are effective-dated, and each monthly MMSDM
archive carries only the versions that became effective in that month. `DISPATCHCONSTRAINT` keeps
referencing a version for as long as it is invoked. A cache populated from 2015-01 therefore has
no definition for a constraint last revised earlier.

Counted on the cache for 2026-06-01 to 2026-09-01, 245 of 14,982 invoked (constraint, effective
date, version) combinations had no `GENCONDATA` row: 211 had an effective date before 2015 and the
rest were the dynamic `$` unit-fix constraints, which have no effective date and are not in any
table. Examples are `N_NIL_TE_B` (2012-07-04), `N_MBTE1_B` (2013-11-25), `F_MAIN+NIL_MG_R5/6/60`
and the four `*_ZERO` interconnector constraints (both 2013-08-21).

Before 2015 NEMWEB hosts no per-table `PUBLIC_DVD_*` files, only one `MMSDM_<yyyy>_<mm>.zip` per
month of 1.5 to 2.2 GB, so `populate` returns 404 for those months. Fetching all 66 months from
2009-07 would be about 130 GB.

## Decision

`populate_legacy_archive` reads each monthly archive with HTTP range requests (`ZipReader` over a
lazily fetched byte vector), extracts the one nested `PUBLIC_DVD_<table>_<yyyymm>010000.zip` per
table, and passes it through the existing extract and parquet pipeline. A month costs a few MB.
`populate` and `_add_data` take a `fetch_archive` function so both sources share the Hive writing,
skip-existing and error handling. The retry loop of `_download_and_cache` is now `_fetch_with_retry`,
shared with the range reads, so a rate-limiting 403 backs off the same way.

The default tables are the four that define constraints, and the range is limited to
2009-07 to 2014-12.

## Consequences

- Constraints revised before 2015 resolve in the cache. The remaining undefined version was
  `VT_000` at 2008-08-05, which predates the oldest monthly archive on NEMWEB.
- A fresh cache needs this call once in addition to `populate`; nothing calls it automatically.
- `SPDREGIONCONSTRAINT` has no entry in some months, which logs a missing-data error and writes no
  partition, so those months are re-checked on every run.
- ADR 0039's built-in definitions for the four `*_ZERO` constraints are redundant once the cache is
  backfilled; a published definition takes precedence, so they remain harmless.
