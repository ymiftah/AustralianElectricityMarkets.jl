# ISP 2026 extracted cache

The persistent database is `/home/simba/.nemdb_cache/ISP/2026/isp.duckdb`.
It contains the complete raw XML and CSV contents of the current 2026 ISP model package
downloaded from AEMO on 28 October 2026. The download page dates this set 28 September 2026.

The [AEMO 2026 ISP page](https://www.aemo.com.au/energy-systems/major-publications/integrated-system-plan-isp/2026-integrated-system-plan-isp)
provides separate model, hydro, solar, wind and timeslice archives. All five were downloaded
through its browser links and their contents checked during ZIP extraction.

## Database contents

| Contents | Imported |
| --- | --- |
| Scenario XML tables | 81: all 27 tables in each of three scenarios |
| XML records | 712,537 |
| Source CSV files | 745 |
| Distinct CSV tables | 726, deduplicated by SHA-256 of the source bytes |
| Distinct CSV table rows | 6,642,344 |
| Data File references | 1,683: 561 per scenario |
| Missing Data File references | 0 |
| Database size after validation and provenance finalisation | 864,301,056 bytes |

The scenario schemas are `accelerated_transition`, `slower_growth` and `step_change`.
Each contains all 27 source `t_*` tables. Physical CSV tables live in `traces`, with names
`f_<source_sha256>`. XML fields and original CSV columns are stored as `VARCHAR` to retain
source values, date labels, period column names and precision. Absent XML fields are SQL NULL.

| CSV family | Source files across the package | Distinct physical tables |
| --- | --- | --- |
| demand | 45 | 45 |
| dnsp | 114 | 102 |
| gas | 33 | 27 |
| hydro | 14 | 14 |
| load_subtractor | 27 | 27 |
| rooftop pv | 57 | 57 |
| solar | 248 | 247 |
| timeslice | 1 | 1 |
| wind | 206 | 206 |

Shared trace files are stored once and linked to every scenario that references them.
Distinct source files with identical bytes share a physical table while retaining separate
file catalogue entries. CSV column layouts are preserved, including hydro files with date
keys and files with a `Year` key followed by generator columns.

## Finding and querying data

The `cache_meta` schema contains:

- `xml_tables`: scenario, table name, source XML path/hash, source columns and record count.
- `trace_files`: source filename/path, family, scenario where applicable, hash, physical
  table location, columns and record count.
- `trace_references`: scenario and Data File object IDs mapped to filenames and physical tables.
- `provenance`: the release page, archive URLs, revision IDs, source hashes and import details.
- `row_count_checks`: source and imported record counts for all 807 physical data tables.

Each scenario also has a `trace_bindings` view. It joins property records tagged directly
to Data File objects to their imported CSV tables, retaining property, membership, object
and action IDs.

```sql
SELECT * FROM step_change.t_object LIMIT 10;

SELECT table_name, row_count
FROM cache_meta.xml_tables
WHERE scenario = 'step_change'
ORDER BY table_name;

SELECT property_name, relative_path, table_schema, table_name
FROM step_change.trace_bindings
LIMIT 10;

SELECT *
FROM cache_meta.trace_files
WHERE family = 'wind'
ORDER BY filename;
```

Use the returned schema and table name to query a physical CSV table. Numeric casts and
calendar interpretation can be applied by downstream readers. This extraction preserves raw
inputs; it does not evaluate variables, tag actions, effective property precedence or
reference-year substitutions, and does not construct a PowerSystems system.

For direct Julia access, open the persistent file explicitly:

```julia
using DuckDB, DataFrames

db = DuckDB.DB(expanduser("~/.nemdb_cache/ISP/2026/isp.duckdb"))
objects = DataFrame(DuckDB.execute(db, "SELECT * FROM step_change.t_object"))
```

## Source files and reproducibility

Archives and extracted source files are retained on the disk-backed volume at
`/run/media/simba/Store/aem_validation/isp2026/2026-09-28/`.
`downloads.json` records each public archive URL, revision and SHA-256.
The database is self-contained and querying imported tables does not require the raw files.

The cache directory also contains `isp.manifest.json`, `isp.sources.json` and
`isp.verification.json`, recording import counts, source provenance and verification results.
The import SQL, intermediate XML JSON records and DuckDB log are retained in the
source directory's `import_20261028T031437Z` folder.

The [standalone extractor](extract_isp_cache.py) uses Python's standard library and the
DuckDB CLI supplied by `DuckDB_jll`; it does not change the Julia package environment.
It requires an extracted source directory containing `raw/` and `downloads.json`, checks
the archive hashes and refuses to overwrite an existing database.

```bash
python3 docs/analysis/extract_isp_cache.py \
    --source /run/media/simba/Store/aem_validation/isp2026/2026-09-28 \
    --output /path/to/a/new/isp.duckdb \
    --duckdb /path/to/duckdb
```

The earlier [local-package inventory](isp2026-inventory.md) describes the older source copy
found in Downloads before these fresh downloads. Its counts differ from this release.

## Validation

Source row counts and original column names match for all 807 physical data tables.
Every Data File filename resolves to an imported CSV table. A separate source-to-cache check
confirmed all 712,537 XML records field for field, the first and last records in all 726
physical CSV tables, and 45 foreign-key paths with no orphan records.
The results are also retained in the source directory's `content_verification` folder.
