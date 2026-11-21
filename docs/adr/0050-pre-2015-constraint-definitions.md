# 0050 Constraint definitions from pre-2015 monolithic archives

## Status

Accepted

## What

- `GENCONDATA` and the `SPD*CONSTRAINT` term tables are effective-dated and each monthly MMSDM archive carries only versions that became effective that month, while `DISPATCHCONSTRAINT` keeps referencing a version while it is invoked. A cache populated from 2015-01 therefore lacks definitions for constraints last revised earlier (for example `N_NIL_TE_B`, 2012-07-04).
- `populate_legacy_archive` backfills them. A fresh cache needs this call once in addition to `populate`; nothing calls it automatically.

## How

- Before 2015 NEMWEB hosts only one `MMSDM_<yyyy>_<mm>.zip` per month (1.5 to 2.2 GB), so `populate` returns 404. `populate_legacy_archive` reads each archive with HTTP range requests (`ZipReader` over a lazily fetched byte vector), extracts the nested `PUBLIC_DVD_<table>_<yyyymm>010000.zip` per table, and feeds it to the normal extract and parquet pipeline. A month costs a few MB.
- `populate` and `_add_data` take a `fetch_archive` function so both sources share Hive writing, skip-existing and error handling. `_fetch_with_retry` is shared by full downloads and range reads.
- Defaults are the four definition tables (`CONSTRAINT_DEFINITION_TABLES`) and 2009-07 to 2014-12, the first MMSDM monthly archive to the last month with no per-table files.
- `SPDREGIONCONSTRAINT` has no entry in some months, which logs a missing-data error and writes no partition, so those months are re-checked on every run.
- The built-in `*_ZERO` definitions of [0039](0039-interconnector-zero-constraints.md) become redundant after backfill; a published definition takes precedence.

## Why

- Downloading all 66 months whole would be about 130 GB; range reads fetch only the four tables.
- Dynamic `$` unit-fix constraints have no effective date and appear in no table, so they are not covered here.
