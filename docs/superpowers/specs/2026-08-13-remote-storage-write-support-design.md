# Remote storage write support for the NEMWEB archive cache

Date: 2026-08-13

## Problem

`HiveConfiguration.filesystem` already documents `s3`/`gs` as valid values, and
the *read* path (`aem_connect` + `read_hive`/`_parse_hive_root` in
`src/data_utils.jl` and `src/parser.jl`) already supports them via DuckDB's
`httpfs` extension.

The NEMWEB *download/cache-write* path does not. `DataSource`'s constructor
(`src/AustralianElectricityMarketsData/nemweb_load/source.jl`) explicitly
rejects any non-local `filesystem`:

```julia
islocal(config) || throw(
    ArgumentError("DataSource requires a local cache filesystem, got filesystem=$(get_filesystem(config))")
)
```

This guard exists because several functions downstream of it assume a local
filesystem and would otherwise behave incorrectly (not merely raise an
error) against `s3://`/`gs://` paths:

1. `_add_data`'s partition clear (`archive.jl:13`) — `isdir`/`rm` on a remote
   URI string; `isdir` just returns `false`, so the clear silently no-ops.
2. `_csv_to_parquet`'s `mkpath(path)` (`parquet.jl:224`) — would create a
   bogus local directory tree literally named after the URI's components
   (e.g. a directory named `gs:`) before failing.
3. `cached_date_range` (`source.jl:58-74`) and `populate`'s inline
   `data_exists` check (`archive.jl:78-83`) both use `isdir`/`readdir`
   directly — always `false`/empty for a remote path, so `populate` would
   treat remote data as permanently uncached.
4. `_new_duckdb_connection()` (`parquet.jl:7-18`) never loads `httpfs`, so
   any `COPY ... TO 's3://...'`/`'gs://...'` would fail outright.

Goal: make `DataSource` + `populate`/`_add_data` work against `s3://`/`gs://`
hive locations, reusing the exact mechanism the read path already trusts
(DuckDB `httpfs`, ambient credentials), without introducing a new
per-provider abstraction.

**Errata (found while writing the implementation plan):** `aem_connect`'s
existing httpfs-loading call —
`DuckDB.execute(db, "INSTALL httpfs; LOAD httpfs;")`
(`src/data_utils.jl:20`) — is itself broken on the pinned DuckDB.jl version
(1.5.2): a single semicolon-joined multi-statement string raises
`DuckDB.QueryException("Invalid Input Error: Cannot prepare multiple
statements at once!")`, confirmed directly. No existing test constructs
`aem_connect` with a non-`"file"` filesystem, so this was never caught. The
"read path already supports S3/GS" premise above was true by code-reading,
not by execution. The implementation plan fixes this (two separate
`execute` calls) as part of the same task that adds the equivalent
httpfs-loading to `_new_duckdb_connection`, so the bug isn't propagated into
new code.

## Non-goals

- No new credential configuration surface on `HiveConfiguration`. Both S3 and
  GS credentials are picked up ambiently by DuckDB's `httpfs` (AWS env
  vars/instance profile, `GOOGLE_APPLICATION_CREDENTIALS`, etc.), exactly as
  `aem_connect` already assumes for reads.
- No explicit remote partition-clearing/delete step. `_add_data`'s local
  `rm`-before-rewrite behavior is *not* replicated remotely; remote writes
  rely solely on `COPY ... (OVERWRITE_OR_IGNORE TRUE)`.
  - **Accepted risk:** unlike local, a remote partition that gets
    re-populated (e.g. `force_new=true`, or a second `populate` call) is not
    cleared first. If DuckDB's per-run PARTITION_BY output filenames aren't
    stable across runs, repeated writes to the same partition could
    accumulate duplicate rows rather than being replaced. This is a
    deliberate scope cut, not an oversight — mitigated in practice by the
    existence check in `populate` (below), which means a partition is only
    rewritten when the caller explicitly forces it or when no data was
    detected there yet.
- No new S3 SDK / GoogleCloud.jl dependency. Everything routes through
  DuckDB `httpfs`, matching the existing read path.

## Design

### 1. Relocate `_parse_hive_root` into `configurations.jl`

`islocal`/`get_filesystem` already live in `src/configurations.jl` alongside
`HiveConfiguration`. `_parse_hive_root` (currently in `src/parser.jl`) builds
the correct root path/URI for a config and belongs with them — both the read
path (`parser.jl`) and the write path
(`AustralianElectricityMarketsData/nemweb_load/source.jl`) need it, and
`source.jl`'s module (`AustralianElectricityMarketsData`) is `include`d
*before* `parser.jl` in `AustralianElectricityMarkets.jl`, so `source.jl`
cannot `using` a binding that doesn't exist yet at that point in load order.
Moving the function to `configurations.jl` (included first) resolves this
without reordering top-level includes.

No behavior change to `_parse_hive_root` itself — pure relocation.

### 2. `DataSource` construction

- Drop the `islocal(config) || throw(...)` guard.
- Replace the constructor's `joinpath(config.hive_location, table_name)` with
  `joinpath(_parse_hive_root(config), table_name)`, so `path` is a correct
  root for both local and remote in one code path instead of two
  (local-only) implementations that could drift.

### 3. `_new_duckdb_connection(config)`

- Takes `config::HiveConfiguration` (currently takes nothing).
- When `!islocal(config)`, runs `INSTALL httpfs; LOAD httpfs;`, mirroring
  `aem_connect` (`src/data_utils.jl:17-23`).
- All call sites in `parquet.jl`/`archive.jl` pass `source.config`-derived
  config through (see below for how `_add_data`/`_csv_to_parquet` obtain it —
  `DataSource` does not currently store `config`, only the resolved `path`;
  simplest fix is to thread `config` alongside `source`, or store `filesystem`
  directly on `DataSource` — implementation plan to decide the minimal
  threading).

### 4. `_csv_to_parquet` — skip `mkpath` for remote

- `mkpath(path)` (`parquet.jl:224`) only runs when `islocal(config)`. Remote
  writes don't need (and can't use) a pre-created directory — DuckDB's `COPY
  ... TO 's3://...'` creates the prefix implicitly.

### 5. Existence checks — new `_partition_has_data` helper

Replaces the repeated `isdir(dir) && any(endswith(f, ".parquet") for f in
readdir(dir))` pattern in `cached_date_range` (`source.jl`) and `populate`'s
inline check (`archive.jl:78-83`):

```julia
function _partition_has_data(config::HiveConfiguration, partition_dir::String)::Bool
    if islocal(config)
        return isdir(partition_dir) && any(endswith(f, ".parquet") for f in readdir(partition_dir))
    else
        conn = _new_duckdb_connection(config)
        try
            result = DBInterface.execute(conn, "SELECT COUNT(*) AS n FROM glob('$partition_dir/*.parquet')")
            return DataFrame(result).n[1] > 0
        finally
            DBInterface.close!(conn)
        end
    end
end
```

Local branch is byte-for-byte the existing logic — zero behavior change for
current local users.

`cached_date_range`'s outer enumeration (which `archive_month=...`
directories exist at all — currently `readdir(source.path)`) also needs a
remote path: for `!islocal(config)`, list via DuckDB
`glob('$(source.path)/*/')` and parse the same `archive_month=YYYY-MM-DD`
pattern out of the returned directory paths instead of `Base.readdir`
entries.

### 6. `_add_data` — remote partition clear becomes a no-op

```julia
if islocal(source.config)
    isdir(partition_dir) && rm(partition_dir; recursive = true, force = true)
end
```

No remote-delete branch (see Non-goals).

## Data flow (remote case)

1. `aem_connect(HiveConfiguration(filesystem="gs", hive_location="bucket/prefix"))`
   → loads `httpfs`.
2. `get_table(db, :DISPATCHPRICE)` → `DataSource(...)` with `path =
   "gs://bucket/prefix/DISPATCHPRICE"` (via relocated `_parse_hive_root`).
3. `populate(db, :DISPATCHPRICE, start, stop)` → for each month, checks
   `_partition_has_data` (DuckDB `glob()` over `httpfs`); skips if already
   present, else calls `_add_data`.
4. `_add_data`: downloads NEMWEB zip to local scratch (unchanged —
   `_local_tmp_dir()` stays local, this is just staging), skips the remote
   partition clear, runs `_csv_to_parquet` whose `COPY ... TO
   'gs://bucket/prefix/DISPATCHPRICE'` writes straight to GCS via `httpfs`.

## Testing

- Existing local-path tests (`test/test-nemweb-load.jl`) are unaffected —
  `islocal` branches keep the exact `Base.isdir`/`readdir`/`rm`/`mkpath`
  calls they already exercise.
- New test group exercises the real remote path end-to-end against
  `gs://australian_electricity_markets`:
  - Skips (does not fail) if the bucket isn't reachable/credentialed, so
    `julia test/runtests.jl` stays usable without GCS access configured.
  - Each run writes under a fresh randomized prefix (e.g.
    `gs://australian_electricity_markets/_test/$(uuid4())/...`) and deletes
    it in a `finally` via `gcloud storage rm -r` (test-only shell-out; not
    part of the package's runtime code, so it does not reintroduce a
    Python/CLI runtime dependency into the library itself).
  - Covers: `DataSource` construction with `filesystem="gs"`, `_add_data`
    writing a small fixture through to real GCS parquet, `populate`'s
    existence check correctly skipping a second call for the same
    already-populated month.
- S3 gets the same code path (`!islocal` branch is filesystem-agnostic; only
  the URI scheme differs) but is not exercised by an executed test — no S3
  bucket was named. Covered by symmetry/code-reading only, for now.

## Open implementation detail

`DataSource` currently stores only the resolved `path` string, not the
`HiveConfiguration` it was built from — but `_add_data`/`_partition_has_data`
need `islocal(config)`/`_new_duckdb_connection(config)` at points where only
`source::DataSource` is in scope. The implementation plan should decide the
minimal way to carry that through (e.g. store `config` on `DataSource`, or
just the two fields actually needed — `filesystem`). Left open here since
it's a mechanical threading decision, not a design decision.
