# Remote Storage Write Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the NEMWEB archive cache (`DataSource`/`populate`/`_add_data`) write to `s3://`/`gs://` hive locations, not just local disk, using the same DuckDB `httpfs` mechanism the read path already claims to support.

**Architecture:** Thread a `filesystem::String` (already a `HiveConfiguration` field: `"file"`/`"s3"`/`"gs"`) through `DataSource` and the small set of functions that currently call `Base.isdir`/`readdir`/`rm`/`mkpath` directly. Each of those functions branches on `islocal(filesystem)`: local keeps its exact current behavior (zero risk of regression), remote routes through DuckDB `httpfs` (`glob()` for listing/existence, `COPY ... TO 's3://...'`/`'gs://...'` for writes — already how DuckDB writes parquet, no new dependency).

**Tech Stack:** Julia, DuckDB.jl 1.5.2 (`httpfs` extension), existing `AustralianElectricityMarketsData` module.

**Spec:** `docs/superpowers/specs/2026-08-13-remote-storage-write-support-design.md`

## Global Constraints

- No new `HiveConfiguration` fields. Credentials are ambient only (DuckDB's built-in AWS/GCS credential chain) — never read, store, or log a credential in this codebase.
- No remote partition-delete step. `_add_data`'s local `rm`-before-rewrite is *not* replicated remotely; remote relies solely on `COPY ... (OVERWRITE_OR_IGNORE TRUE)`. This is an accepted, documented risk (see spec's Non-goals), not something to "fix" mid-implementation.
- No new S3/GS SDK dependency (no AWSS3.jl, no GoogleCloud.jl). Everything routes through DuckDB `httpfs`.
- Every local-filesystem code path must be byte-for-byte unchanged in behavior — the `islocal` branch in every function below must be exactly what the function did before this plan, so all existing local tests keep passing unmodified except where a test is explicitly named for replacement below.
- Two separate `DuckDB.execute`/`DBInterface.execute` calls for `INSTALL httpfs`/`LOAD httpfs` — a single semicolon-joined string raises `DuckDB.QueryException("Invalid Input Error: Cannot prepare multiple statements at once!")` on DuckDB.jl 1.5.2 (confirmed directly; this is why `aem_connect`'s current one-string version is being fixed, not copied).

---

### Task 1: Relocate `_parse_hive_root`; add `islocal(filesystem::String)`

**Files:**

- Modify: `src/configurations.jl`
- Modify: `src/parser.jl`
- Test: `test/datareader.jl` (existing, must still pass — exercises `read_hive` → `_parse_hive_root` indirectly)
- Test: new testset in `test/test-nemweb-load.jl`

**Interfaces:**

- Produces: `AustralianElectricityMarkets._parse_hive_root(config::HiveConfiguration)::String` (moved, unchanged behavior) — now defined in `configurations.jl` instead of `parser.jl`.
- Produces: `AustralianElectricityMarkets.islocal(filesystem::String)::Bool` — new method; `islocal(config::HiveConfiguration)` now delegates to it.

**Why this task exists:** `source.jl` (in the `AustralianElectricityMarketsData` submodule, `include`d *before* `parser.jl` in `AustralianElectricityMarkets.jl`) needs `_parse_hive_root` to build `DataSource.path` for both local and remote in one code path. It can't `using ..AustralianElectricityMarkets: _parse_hive_root` while that function still lives in `parser.jl`, since `parser.jl` hasn't been `include`d yet at that point in module load order. Moving the function to `configurations.jl` (included first, alongside `islocal`/`get_filesystem` which it already depends on) fixes this with no reordering of top-level includes.

- [ ] **Step 1: Write the failing test for `islocal(filesystem::String)`**

Add to `test/test-nemweb-load.jl`, in a new section after the existing `@testset` blocks (before `# ══...` section D, i.e. right after the imports/fixtures, in a new section labelled appropriately — place it as a new `# A2.` section right before `# D. DataSource construction`):

```julia
# ══════════════════════════════════════════════════════════════════════════════
# A2. islocal / _parse_hive_root — shared local-vs-remote path logic
# ══════════════════════════════════════════════════════════════════════════════

@testset "islocal(filesystem::String): true only for \"file\"" begin
    @test AustralianElectricityMarkets.islocal("file")
    @test !AustralianElectricityMarkets.islocal("s3")
    @test !AustralianElectricityMarkets.islocal("gs")
end

@testset "islocal(config): delegates to islocal(filesystem)" begin
    @test AustralianElectricityMarkets.islocal(HiveConfiguration(filesystem = "file"))
    @test !AustralianElectricityMarkets.islocal(HiveConfiguration(filesystem = "s3"))
end

@testset "_parse_hive_root: local returns hive_location, remote returns scheme://hive_location" begin
    @test AustralianElectricityMarkets._parse_hive_root(HiveConfiguration(hive_location = "/tmp/x", filesystem = "file")) == "/tmp/x"
    @test AustralianElectricityMarkets._parse_hive_root(HiveConfiguration(hive_location = "bucket/prefix", filesystem = "gs")) == "gs://bucket/prefix"
    @test AustralianElectricityMarkets._parse_hive_root(HiveConfiguration(hive_location = "bucket/prefix", filesystem = "s3")) == "s3://bucket/prefix"
end
```

You'll need `using AustralianElectricityMarkets` and `HiveConfiguration` already in scope — both are already imported at the top of `test/test-nemweb-load.jl` (`AustralianElectricityMarkets` is implicitly available because `runtests.jl`/direct run both load it; `HiveConfiguration` is not currently imported into this file's namespace — check the top-of-file `using` block and add `HiveConfiguration` to the explicit import list from `AustralianElectricityMarkets` if it isn't already reachable, since the current imports only pull names from `AustralianElectricityMarketsData`).

Concretely, change line 1 of `test/test-nemweb-load.jl` from:

```julia
using AustralianElectricityMarkets: AustralianElectricityMarketsData
```

to:

```julia
using AustralianElectricityMarkets: AustralianElectricityMarketsData, HiveConfiguration
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `julia --project=. -e 'using Test, AustralianElectricityMarkets; include("test/test-nemweb-load.jl")'`
Expected: FAIL — `UndefVarError` for `islocal(::String)` (only the `HiveConfiguration` method exists) and for `_parse_hive_root` (not yet reachable/moved).

- [ ] **Step 3: Move `_parse_hive_root` into `configurations.jl`, add `islocal(filesystem::String)`**

In `src/configurations.jl`, replace:

```julia
islocal(config::HiveConfiguration) = config.filesystem == "file"
get_filesystem(config::HiveConfiguration) = config.filesystem
```

with:

```julia
islocal(filesystem::String) = filesystem == "file"
islocal(config::HiveConfiguration) = islocal(config.filesystem)
get_filesystem(config::HiveConfiguration) = config.filesystem

"""
    _parse_hive_root(config::HiveConfiguration)

Construct the correct path to the Hive dataset based on the specified filesystem.

# Arguments
- `config::HiveConfiguration`: The configuration object containing filesystem and location details.
"""
function _parse_hive_root(config::HiveConfiguration)
    if islocal(config)
        return config.hive_location
    else
        prefix = get_filesystem(config)
        return "$(prefix)://" * config.hive_location
    end
end
```

In `src/parser.jl`, delete the now-duplicate function (lines 26-41 in the current file — the `"""..._parse_hive_root..."""` docstring plus `function _parse_hive_root(...) ... end` block). Leave `read_hive` (which calls `_parse_hive_root`) untouched — it resolves fine since `_parse_hive_root` is still in the same top-level `AustralianElectricityMarkets` module namespace, just defined in a different file.

- [ ] **Step 4: Run the test to verify it passes**

Run: `julia --project=. -e 'using Test, AustralianElectricityMarkets; include("test/test-nemweb-load.jl")'`
Expected: PASS for the three new testsets. (Other testsets in this file will still fail at this point if they depend on later tasks — that's expected; just confirm the three new ones pass and nothing *new* broke relative to before this step.)

- [ ] **Step 5: Run the full existing read-path tests to confirm no regression**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'` and specifically watch `datareader.jl`/`regionmodel.jl`/`timeseries_setters.jl` output (these exercise `read_hive`/`_parse_hive_root` indirectly via `aem_connect`).
Expected: same pass/fail status as before this task for all tests other than the three new ones above and any test-nemweb-load.jl failures that are expected to be fixed by later tasks.

- [ ] **Step 6: Commit**

```bash
git add src/configurations.jl src/parser.jl test/test-nemweb-load.jl
git commit -m "Relocate _parse_hive_root to configurations.jl, add islocal(::String)"
```

---

### Task 2: `_new_duckdb_connection` loads `httpfs` for remote; fix `aem_connect`'s multi-statement bug

**Files:**

- Modify: `src/AustralianElectricityMarketsData/nemweb_load/parquet.jl`
- Modify: `src/data_utils.jl`
- Test: new testset in `test/test-nemweb-load.jl`

**Interfaces:**

- Consumes: `islocal(filesystem::String)` from Task 1.
- Produces: `_new_duckdb_connection(filesystem::String = "file")::DuckDB.DB` (signature change — was `_new_duckdb_connection()`; existing zero-arg call sites `read_parquet_file`/`write_hive_parquet` keep working unchanged via the default).

- [ ] **Step 1: Write the failing test**

Add to `test/test-nemweb-load.jl`, in the same new `A2` section as Task 1 (after the `_parse_hive_root` tests):

```julia
@testset "_new_duckdb_connection: local (default) works with no network access assumptions" begin
    conn = _new_duckdb_connection()
    try
        @test DBInterface.execute(conn, "SELECT 1 AS x") |> DataFrame == DataFrame(x = [1])
    finally
        DBInterface.close!(conn)
    end
end

@testset "_new_duckdb_connection: remote filesystem loads httpfs without error" begin
    conn = _new_duckdb_connection("gs")
    try
        @test DBInterface.execute(conn, "SELECT 1 AS x") |> DataFrame == DataFrame(x = [1])
    finally
        DBInterface.close!(conn)
    end
end
```

You'll need `_new_duckdb_connection` importable in this test file — add it to the existing multi-line `using AustralianElectricityMarkets.AustralianElectricityMarketsData: ...` import block near the top of `test/test-nemweb-load.jl` (it currently imports `DataSource, get_table, MissingDataError, _TABLE_SPECS, ARCHIVE_MONTH_PARTITION, _extract_csv_entry, _filter_d_lines, _peek_header_columns, _csv_to_parquet, write_hive_parquet, read_parquet_file` — append `_new_duckdb_connection`).

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Test, AustralianElectricityMarkets; include("test/test-nemweb-load.jl")'`
Expected: FAIL — `_new_duckdb_connection("gs")` errors with `MethodError` (no 1-arg method yet).

- [ ] **Step 3: Update `_new_duckdb_connection` in `parquet.jl`**

Replace (`src/AustralianElectricityMarketsData/nemweb_load/parquet.jl:1-19`):

```julia
"""
    _new_duckdb_connection() -> DuckDB.DB

Open a DuckDB connection configured to spill to a real (non-tmpfs) disk
directory once memory use crosses a conservative bound, rather than growing
unbounded.
"""
function _new_duckdb_connection()
    # Without this, an unconfigured in-memory DuckDB.DB() has nowhere to spill
    # a large sort/aggregate to, and can be OOM-killed by the OS on wide,
    # multi-million-row tables (confirmed directly: a bare connection
    # processing BIDPEROFFER_D was killed at ~7.5GB resident).
    conn = DuckDB.DB()
    spill_dir = expanduser("~/.cache/aem_duckdb_spill")
    mkpath(spill_dir)
    DBInterface.execute(conn, "SET memory_limit='2GB'")
    DBInterface.execute(conn, "SET temp_directory='$spill_dir'")
    return conn
end
```

with:

```julia
"""
    _new_duckdb_connection(filesystem::String = "file") -> DuckDB.DB

Open a DuckDB connection configured to spill to a real (non-tmpfs) disk
directory once memory use crosses a conservative bound, rather than growing
unbounded. Loads the `httpfs` extension when `filesystem` is remote
(`"s3"`/`"gs"`), so subsequent `COPY`/`glob()` calls can reach it.
"""
function _new_duckdb_connection(filesystem::String = "file")
    # Without this, an unconfigured in-memory DuckDB.DB() has nowhere to spill
    # a large sort/aggregate to, and can be OOM-killed by the OS on wide,
    # multi-million-row tables (confirmed directly: a bare connection
    # processing BIDPEROFFER_D was killed at ~7.5GB resident).
    conn = DuckDB.DB()
    if !islocal(filesystem)
        # Two separate calls, not one "INSTALL httpfs; LOAD httpfs;" string —
        # DuckDB.jl 1.5.2 raises "Cannot prepare multiple statements at once!"
        # on a semicolon-joined multi-statement string (confirmed directly).
        DuckDB.execute(conn, "INSTALL httpfs;")
        DuckDB.execute(conn, "LOAD httpfs;")
    end
    spill_dir = expanduser("~/.cache/aem_duckdb_spill")
    mkpath(spill_dir)
    DBInterface.execute(conn, "SET memory_limit='2GB'")
    DBInterface.execute(conn, "SET temp_directory='$spill_dir'")
    return conn
end
```

- [ ] **Step 4: Fix the same bug in `aem_connect` (`src/data_utils.jl`)**

Replace:

```julia
function aem_connect(config::HiveConfiguration = HiveConfiguration())
    db = DuckDB.DB()
    if !islocal(config)
        DuckDB.execute(db, "INSTALL httpfs; LOAD httpfs;")
    end
    return AEMDB(; db, config)
end
```

with:

```julia
function aem_connect(config::HiveConfiguration = HiveConfiguration())
    db = DuckDB.DB()
    if !islocal(config)
        # Two separate calls — see _new_duckdb_connection for why.
        DuckDB.execute(db, "INSTALL httpfs;")
        DuckDB.execute(db, "LOAD httpfs;")
    end
    return AEMDB(; db, config)
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `julia --project=. -e 'using Test, AustralianElectricityMarkets; include("test/test-nemweb-load.jl")'`
Expected: PASS for both new testsets.

- [ ] **Step 6: Commit**

```bash
git add src/AustralianElectricityMarketsData/nemweb_load/parquet.jl src/data_utils.jl test/test-nemweb-load.jl
git commit -m "Load httpfs for remote DuckDB connections; fix multi-statement INSTALL/LOAD bug"
```

---

### Task 3: `DataSource` accepts remote filesystems

**Files:**

- Modify: `src/AustralianElectricityMarketsData/nemweb_load/source.jl`
- Modify: `src/AustralianElectricityMarketsData/AustralianElectricityMarketsData.jl` (import `_parse_hive_root`)
- Test: `test/test-nemweb-load.jl` (modifies section D)

**Interfaces:**

- Consumes: `_parse_hive_root(config)` (Task 1), `islocal` (Task 1).
- Produces: `DataSource` struct gains a 6th field, `filesystem::String`. All later tasks read `source.filesystem` instead of re-deriving locality from `source.path`.

- [ ] **Step 1: Write the failing tests**

In `test/test-nemweb-load.jl`, replace the existing testset (section D, around current line 322-325):

```julia
@testset "DataSource: rejects a non-local HiveConfiguration" begin
    config = HiveConfiguration(hive_location = "bucket/path", filesystem = "s3")
    @test_throws ArgumentError DataSource("T", ["C"], config)
end
```

with:

```julia
@testset "DataSource: accepts a remote HiveConfiguration and builds a scheme:// path" begin
    config = HiveConfiguration(hive_location = "bucket/path", filesystem = "s3")
    source = DataSource("T", ["C"], config)
    @test source.path == "s3://bucket/path/T"
    @test source.filesystem == "s3"
end

@testset "DataSource: filesystem field matches config for local sources" begin
    tmpdir = mktempdir()
    source = DataSource("T", ["C"], HiveConfiguration(hive_location = tmpdir))
    @test source.filesystem == "file"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Test, AustralianElectricityMarkets; include("test/test-nemweb-load.jl")'`
Expected: FAIL — old test's `@test_throws ArgumentError` no longer exists (replaced), new tests fail with `type DataSource has no field filesystem` / the old constructor still throwing for `filesystem="s3"`.

- [ ] **Step 3: Update `DataSource` struct and constructor in `source.jl`**

Replace the whole file's struct + constructor (current lines 1-48):

```julia
"""
    DataSource

Immutable description of one NEMWEB MMS table, cached as Hive-partitioned
parquet under `config.hive_location`. Construction is pure — it does not
touch the filesystem; `_add_data` creates `path` lazily on first write.

# Fields
- `table_name::String`: Name of the table
- `table_columns::Vector{String}`: Columns to include
- `table_sort_by::Vector{String}`: Columns to sort by within each output file (row-group locality; not an enforced uniqueness constraint)
- `partitions::Vector{String}`: Partition columns
- `path::String`: Path to parquet dataset (local path, or `scheme://...` URI for remote)
- `filesystem::String`: The `HiveConfiguration.filesystem` this source was built from (`"file"`, `"s3"`, `"gs"`)
"""
struct DataSource
    table_name::String
    table_columns::Vector{String}
    table_sort_by::Vector{String}
    partitions::Vector{String}
    path::String
    filesystem::String
end

"""
    DataSource(table_name, table_columns, config=HiveConfiguration();
               table_sort_by=String[], add_partitions=String[])

Create a new `DataSource` for a NEMWEB table, rooted at `config.hive_location`.
Works for both local and remote (`s3`/`gs`) `config.filesystem` — path
construction is delegated to `_parse_hive_root`.
"""
function DataSource(
        table_name::String,
        table_columns::Vector{String},
        config::HiveConfiguration = HiveConfiguration();
        table_sort_by::Vector{String} = String[],
        add_partitions::Vector{String} = String[],
    )
    return DataSource(
        table_name,
        table_columns,
        table_sort_by,
        vcat(add_partitions, ARCHIVE_MONTH_PARTITION),
        joinpath(_parse_hive_root(config), table_name),
        get_filesystem(config),
    )
end
```

(The `islocal(config) || throw(ArgumentError(...))` guard is deleted entirely — that's the whole point of this task.)

Leave `cached_date_range` untouched for now (Task 6 rewrites it).

- [ ] **Step 4: Import `_parse_hive_root` into the `AustralianElectricityMarketsData` module**

In `src/AustralianElectricityMarketsData/AustralianElectricityMarketsData.jl`, change:

```julia
using ..AustralianElectricityMarkets: HiveConfiguration, islocal, get_filesystem, AEMDB, PM_MAPPING
```

to:

```julia
using ..AustralianElectricityMarkets: HiveConfiguration, islocal, get_filesystem, _parse_hive_root, AEMDB, PM_MAPPING
```

- [ ] **Step 5: Run test to verify it passes**

Run: `julia --project=. -e 'using Test, AustralianElectricityMarkets; include("test/test-nemweb-load.jl")'`
Expected: PASS for the two new/replaced testsets. The three other pre-existing "DataSource: ..." testsets (fields, partitions, path-is-joinpath) should also still pass unchanged.

- [ ] **Step 6: Commit**

```bash
git add src/AustralianElectricityMarketsData/nemweb_load/source.jl src/AustralianElectricityMarketsData/AustralianElectricityMarketsData.jl test/test-nemweb-load.jl
git commit -m "DataSource: accept remote filesystems, store filesystem field"
```

---

### Task 4: `_csv_to_parquet` skips `mkpath` for remote

**Files:**

- Modify: `src/AustralianElectricityMarketsData/nemweb_load/parquet.jl`
- Test: `test/test-nemweb-load.jl` (existing `_csv_to_parquet` tests must keep passing unchanged; one new test added)

**Interfaces:**

- Produces: `_csv_to_parquet(conn, csv_path, available_cols, table_columns, path, partitions, sort_by, year, month; islocal::Bool = true)` — new trailing keyword argument, default preserves current (local) behavior so the existing 9-positional-arg test helper (`_run_csv_to_parquet` in `test/test-nemweb-load.jl`) needs no changes.

- [ ] **Step 1: Write the failing test**

Add to `test/test-nemweb-load.jl`, near the existing `_csv_to_parquet` tests (search for `"_csv_to_parquet"` to find that section):

```julia
@testset "_csv_to_parquet: islocal=false does not call mkpath" begin
    # DuckDB's local COPY auto-creates at most ONE missing directory level
    # itself (confirmed directly: COPY to a path with a single missing
    # component succeeds even without a prior mkpath; COPY to a path with two
    # or more missing components fails with "Failed to create directory").
    # Nesting the fake path two levels below a fresh tmpdir means: if our
    # code's `islocal && mkpath(path)` runs, the full tree exists before COPY
    # and it succeeds; if it's skipped, COPY fails and no directory is
    # created — a real, deterministic signal instead of relying on "no real
    # s3/gs endpoint" reasoning.
    csv_path = make_nemweb_csv("DISPATCHPRICE", ["REGIONID", "RRP"], [("NSW1", "100.5")])
    try
        conn = DuckDB.DB()
        try
            available_cols = _peek_header_columns(csv_path)
            fake_path = joinpath(mktempdir(), "a", "b")
            @test !isdir(fake_path)
            @test_throws DuckDB.QueryException _csv_to_parquet(
                conn, csv_path, available_cols, ["REGIONID", "RRP"], fake_path,
                [ARCHIVE_MONTH_PARTITION], String[], 2024, 1; islocal = false,
            )
            @test !isdir(fake_path)  # mkpath was never called
        finally
            DBInterface.close!(conn)
        end
    finally
        rm(csv_path; force = true)
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Test, AustralianElectricityMarkets; include("test/test-nemweb-load.jl")'`
Expected: FAIL — `MethodError`, no `islocal` keyword accepted yet.

- [ ] **Step 3: Add the keyword argument in `parquet.jl`**

In `_csv_to_parquet`'s signature (`src/AustralianElectricityMarketsData/nemweb_load/parquet.jl`), change:

```julia
function _csv_to_parquet(
        conn, csv_path::String, available_cols::Vector{String}, table_columns::Vector{String}, path::String,
        partitions::Vector{String}, sort_by::Vector{String}, year::Int, month::Int,
    )
```

to:

```julia
function _csv_to_parquet(
        conn, csv_path::String, available_cols::Vector{String}, table_columns::Vector{String}, path::String,
        partitions::Vector{String}, sort_by::Vector{String}, year::Int, month::Int;
        islocal::Bool = true,
    )
```

And change:

```julia
    mkpath(path)
    sql = """
```

to:

```julia
    islocal && mkpath(path)
    sql = """
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project=. -e 'using Test, AustralianElectricityMarkets; include("test/test-nemweb-load.jl")'`
Expected: PASS for the new test; all pre-existing `_csv_to_parquet`/`_run_csv_to_parquet`-based tests still pass unchanged (they never pass `islocal`, so default `true` preserves current behavior exactly).

- [ ] **Step 5: Commit**

```bash
git add src/AustralianElectricityMarketsData/nemweb_load/parquet.jl test/test-nemweb-load.jl
git commit -m "_csv_to_parquet: skip mkpath for remote writes"
```

---

### Task 5: `_add_data` — conditional partition clear, thread `filesystem` through

**Files:**

- Modify: `src/AustralianElectricityMarketsData/nemweb_load/archive.jl`
- Test: `test/test-nemweb-load.jl` (existing `_add_data`/`populate` tests must keep passing unchanged)

**Interfaces:**

- Consumes: `source.filesystem` (Task 3), `_new_duckdb_connection(filesystem)` (Task 2), `_csv_to_parquet(...; islocal)` (Task 4).

- [ ] **Step 1: Write the failing test**

Add to `test/test-nemweb-load.jl`, near the existing `_add_data`/`populate` tests:

```julia
@testset "_add_data: does not clear an existing partition when source.filesystem is remote" begin
    # Uses a real local tmpdir as the "remote" path stand-in — filesystem="gs" only
    # controls _add_data's *branching*, it doesn't make the path actually remote.
    tmpdir = mktempdir()
    source = DataSource(
        "DISPATCHPRICE", ["SETTLEMENTDATE", "REGIONID", "RRP"],
        HiveConfiguration(hive_location = tmpdir, filesystem = "gs"),
    )
    @test source.filesystem == "gs"
    partition_dir = joinpath(source.path, "archive_month=2024-01-01")
    mkpath(partition_dir)
    sentinel = joinpath(partition_dir, "sentinel.parquet")
    write(sentinel, UInt8[1, 2, 3])

    # _add_data will attempt a real network fetch and fail (no real NEMWEB/gs
    # endpoint reachable the way this test is set up) — that's fine, the only
    # thing under test is that the local sentinel file is never removed by the
    # (skipped, since filesystem != "file") partition-clear step.
    try
        AustralianElectricityMarkets.AustralianElectricityMarketsData._add_data(source, 2024, 1)
    catch
    end
    @test isfile(sentinel)
end
```

You'll need `_add_data` accessible — it's not currently exported/imported into the test file's namespace. Use the fully-qualified form shown above (`AustralianElectricityMarkets.AustralianElectricityMarketsData._add_data`) rather than adding it to the import list, since `_add_data` triggers real network I/O and is intentionally not part of the file's public-surface import block.

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Test, AustralianElectricityMarkets; include("test/test-nemweb-load.jl")'`
Expected: FAIL — current `_add_data` unconditionally clears the partition, so `sentinel` is deleted before the (failing) fetch attempt; `isfile(sentinel)` is `false`.

- [ ] **Step 3: Update `_add_data` in `archive.jl`**

Replace:

```julia
function _add_data(source::DataSource, year::Int, month::Int)
    # `_add_data` is only ever called when `populate` has already decided to
    # (re)fetch this month (not cached, or `force_new=true`), so clearing the
    # partition unconditionally here is always correct, and removes any risk
    # of stale files from a previous run coexisting with fresh ones.
    partition_dir = joinpath(source.path, "$ARCHIVE_MONTH_PARTITION=$(Date(year, month, 1))")
    isdir(partition_dir) && rm(partition_dir; recursive = true, force = true)
```

with:

```julia
function _add_data(source::DataSource, year::Int, month::Int)
    # `_add_data` is only ever called when `populate` has already decided to
    # (re)fetch this month (not cached, or `force_new=true`). For local
    # filesystems, clearing the partition unconditionally here is always
    # correct and removes any risk of stale files from a previous run
    # coexisting with fresh ones. For remote filesystems there is
    # deliberately no equivalent clear step (see
    # docs/superpowers/specs/2026-08-13-remote-storage-write-support-design.md,
    # "Non-goals") — remote rewrites rely solely on COPY's
    # OVERWRITE_OR_IGNORE, which does not guarantee removal of files left
    # over from a differently-shaped previous write to the same partition.
    partition_dir = joinpath(source.path, "$ARCHIVE_MONTH_PARTITION=$(Date(year, month, 1))")
    if islocal(source.filesystem)
        isdir(partition_dir) && rm(partition_dir; recursive = true, force = true)
    end
```

Then, further down in the same function, replace:

```julia
            @info "Writing Hive-partitioned parquet" path = source.path
            conn = _new_duckdb_connection()
            try
                _csv_to_parquet(
                    conn, d_only_path, available_cols, source.table_columns, source.path,
                    source.partitions, source.table_sort_by, year, month,
                )
            finally
                DBInterface.close!(conn)
            end
```

with:

```julia
            @info "Writing Hive-partitioned parquet" path = source.path
            conn = _new_duckdb_connection(source.filesystem)
            try
                _csv_to_parquet(
                    conn, d_only_path, available_cols, source.table_columns, source.path,
                    source.partitions, source.table_sort_by, year, month;
                    islocal = islocal(source.filesystem),
                )
            finally
                DBInterface.close!(conn)
            end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project=. -e 'using Test, AustralianElectricityMarkets; include("test/test-nemweb-load.jl")'`
Expected: PASS for the new test. Pre-existing `_add_data`/`populate` tests (which all use `filesystem="file"` via the default `HiveConfiguration`) still pass unchanged — they exercise the untouched `islocal(source.filesystem)` branch.

- [ ] **Step 5: Commit**

```bash
git add src/AustralianElectricityMarketsData/nemweb_load/archive.jl test/test-nemweb-load.jl
git commit -m "_add_data: skip partition clear and thread filesystem for remote writes"
```

---

### Task 6: Remote-aware existence checks (`_partition_has_data`, `cached_date_range`, `populate`)

**Files:**

- Modify: `src/AustralianElectricityMarketsData/nemweb_load/source.jl`
- Modify: `src/AustralianElectricityMarketsData/nemweb_load/archive.jl`
- Test: `test/test-nemweb-load.jl`

**Interfaces:**

- Produces: `_partition_has_data(source::DataSource, partition_dir::String)::Bool` — local branch is the exact pre-existing inline logic; remote branch queries DuckDB `glob()`.
- Produces: `_partition_dir_names(source::DataSource)::Vector{String}` — local branch is `readdir`; remote branch queries DuckDB `glob('.../*/' )` and extracts bare directory names.
- Consumes: `_new_duckdb_connection` (Task 2), `islocal` (Task 1), `source.filesystem` (Task 3).

**Why local behavior must be byte-identical:** this replaces two independent existing call sites (`cached_date_range`'s inline check, `populate`'s inline check) that both currently use `isdir(dir) && any(endswith(f, ".parquet") for f in readdir(dir))` — moving that exact expression into one shared function, unchanged, is a pure DRY refactor for the local case; only the *new* remote branch is new behavior.

- [ ] **Step 1: Write the failing tests**

Add to `test/test-nemweb-load.jl`, near the `cached_date_range`/`populate` tests:

```julia
@testset "_partition_has_data: local — true iff dir exists and has a .parquet file" begin
    tmpdir = mktempdir()
    source = DataSource("T", ["C"], HiveConfiguration(hive_location = tmpdir))
    partition_dir = joinpath(tmpdir, "T", "archive_month=2024-01-01")

    @test !AustralianElectricityMarkets.AustralianElectricityMarketsData._partition_has_data(source, partition_dir)

    mkpath(partition_dir)
    @test !AustralianElectricityMarkets.AustralianElectricityMarketsData._partition_has_data(source, partition_dir)  # dir exists, no parquet yet

    write(joinpath(partition_dir, "data.parquet"), UInt8[])
    @test AustralianElectricityMarkets.AustralianElectricityMarketsData._partition_has_data(source, partition_dir)
end

@testset "_partition_dir_names: local — matches readdir on source.path" begin
    tmpdir = mktempdir()
    source = DataSource("T", ["C"], HiveConfiguration(hive_location = tmpdir))
    mkpath(joinpath(source.path, "archive_month=2024-01-01"))
    mkpath(joinpath(source.path, "archive_month=2024-02-01"))
    @test Set(AustralianElectricityMarkets.AustralianElectricityMarketsData._partition_dir_names(source)) ==
        Set(["archive_month=2024-01-01", "archive_month=2024-02-01"])
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `julia --project=. -e 'using Test, AustralianElectricityMarkets; include("test/test-nemweb-load.jl")'`
Expected: FAIL — `UndefVarError`, neither function exists yet.

- [ ] **Step 3: Add the two helpers to `source.jl`**

Add near the top of `src/AustralianElectricityMarketsData/nemweb_load/source.jl`, after the `DataSource` constructor and before `cached_date_range`:

```julia
"""
    _partition_has_data(source::DataSource, partition_dir::String) -> Bool

True if `partition_dir` exists and contains at least one `.parquet` file.
Local filesystems use `isdir`/`readdir` directly; remote filesystems query
DuckDB's `glob()` over `httpfs`.
"""
function _partition_has_data(source::DataSource, partition_dir::String)::Bool
    if islocal(source.filesystem)
        return isdir(partition_dir) && any(endswith(f, ".parquet") for f in readdir(partition_dir))
    end
    conn = _new_duckdb_connection(source.filesystem)
    try
        df = DataFrame(DBInterface.execute(conn, "SELECT COUNT(*) AS n FROM glob('$partition_dir/*.parquet')"))
        return df.n[1] > 0
    finally
        DBInterface.close!(conn)
    end
end

"""
    _partition_dir_names(source::DataSource) -> Vector{String}

Bare directory names (e.g. `"archive_month=2024-01-01"`, no path prefix)
directly under `source.path`. Local filesystems use `readdir` directly;
remote filesystems query DuckDB's `glob()` over `httpfs`.
"""
function _partition_dir_names(source::DataSource)::Vector{String}
    if islocal(source.filesystem)
        isdir(source.path) || return String[]
        return readdir(source.path)
    end
    conn = _new_duckdb_connection(source.filesystem)
    try
        df = DataFrame(DBInterface.execute(conn, "SELECT file FROM glob('$(source.path)/*/')"))
        return [basename(rstrip(f, '/')) for f in df.file]
    finally
        DBInterface.close!(conn)
    end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `julia --project=. -e 'using Test, AustralianElectricityMarkets; include("test/test-nemweb-load.jl")'`
Expected: PASS for the two new testsets.

- [ ] **Step 5: Rewire `cached_date_range` to use the new helpers**

In `src/AustralianElectricityMarketsData/nemweb_load/source.jl`, replace:

```julia
function cached_date_range(source::DataSource)::Union{Nothing, Tuple{Date, Date}}
    isdir(source.path) || return nothing

    pattern = Regex("^$(ARCHIVE_MONTH_PARTITION)=(\\d{4}-\\d{2}-\\d{2})\$")
    months = Date[]
    for entry in readdir(source.path)
        m = match(pattern, entry)
        m === nothing && continue
        partition_dir = joinpath(source.path, entry)
        if any(endswith(f, ".parquet") for f in readdir(partition_dir))
            push!(months, Date(m.captures[1]))
        end
    end

    isempty(months) && return nothing
    return (minimum(months), Dates.lastdayofmonth(maximum(months)))
end
```

with:

```julia
function cached_date_range(source::DataSource)::Union{Nothing, Tuple{Date, Date}}
    pattern = Regex("^$(ARCHIVE_MONTH_PARTITION)=(\\d{4}-\\d{2}-\\d{2})\$")
    months = Date[]
    for entry in _partition_dir_names(source)
        m = match(pattern, entry)
        m === nothing && continue
        partition_dir = joinpath(source.path, entry)
        if _partition_has_data(source, partition_dir)
            push!(months, Date(m.captures[1]))
        end
    end

    isempty(months) && return nothing
    return (minimum(months), Dates.lastdayofmonth(maximum(months)))
end
```

(The existing `test/test-nemweb-load.jl` tests for `cached_date_range`, if any — check with `grep -n cached_date_range test/test-nemweb-load.jl` — must still pass unchanged; this is a behavior-preserving refactor for the local case.)

- [ ] **Step 6: Rewire `populate`'s inline check in `archive.jl`**

In `src/AustralianElectricityMarketsData/nemweb_load/archive.jl`, replace:

```julia
        data_exists = false
        if !force_new
            # Check for Hive-partitioned data
            partition_date = Date(year, month, 1)
            partition_dir = joinpath(source.path, "$ARCHIVE_MONTH_PARTITION=$(partition_date)")
            data_exists = isdir(partition_dir) && any(endswith(f, ".parquet") for f in readdir(partition_dir))
        end
```

with:

```julia
        data_exists = false
        if !force_new
            # Check for Hive-partitioned data
            partition_date = Date(year, month, 1)
            partition_dir = joinpath(source.path, "$ARCHIVE_MONTH_PARTITION=$(partition_date)")
            data_exists = _partition_has_data(source, partition_dir)
        end
```

- [ ] **Step 7: Run the full local test file to confirm no regression**

Run: `julia --project=. -e 'using Test, AustralianElectricityMarkets; include("test/test-nemweb-load.jl")'`
Expected: PASS for everything, including the pre-existing `"populate: skips download when Hive partition already exists"` and `"populate: force_new=true overrides existing partition..."` tests and any `cached_date_range` tests.

- [ ] **Step 8: Commit**

```bash
git add src/AustralianElectricityMarketsData/nemweb_load/source.jl src/AustralianElectricityMarketsData/nemweb_load/archive.jl test/test-nemweb-load.jl
git commit -m "Route partition existence checks through DuckDB glob() for remote filesystems"
```

---

### Task 7: End-to-end test against `gs://australian_electricity_markets`

**Files:**

- Modify: `test/Project.toml` (add `UUIDs` stdlib dependency)
- Modify: `test/test-nemweb-load.jl`

**Interfaces:**

- Consumes: everything from Tasks 1-6 — this is the integration test proving the whole chain works against a real bucket.

**Why this is last:** every function this test exercises (`DataSource`, `_add_data`, `populate`, `_partition_has_data`) was already unit-tested against local-filesystem behavior in Tasks 1-6. This task is the one place that touches real network/cloud state, and it should only run once the surrounding logic is already proven correct in isolation.

- [ ] **Step 1: Add `UUIDs` to `test/Project.toml`**

In `test/Project.toml`, add to `[deps]` (alphabetically, after `TimeSeries`):

```toml
UUIDs = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"
```

- [ ] **Step 2: Add the connectivity probe + test group**

Add to `test/test-nemweb-load.jl`, in a new final section:

```julia
using UUIDs: uuid4

# ══════════════════════════════════════════════════════════════════════════════
# H. Remote (GS) end-to-end — real bucket, skipped if unreachable
# ══════════════════════════════════════════════════════════════════════════════

const _GS_TEST_BUCKET = "australian_electricity_markets"

function _gs_test_reachable()
    conn = _new_duckdb_connection("gs")
    try
        DBInterface.execute(conn, "SELECT COUNT(*) FROM glob('gs://$_GS_TEST_BUCKET/*')")
        return true
    catch e
        @info "Skipping GS end-to-end tests — bucket unreachable/uncredentialed" exception = e
        return false
    finally
        DBInterface.close!(conn)
    end
end

if _gs_test_reachable()
    @testset "Remote (GS): DataSource + _add_data + populate against a real bucket" begin
        test_prefix = "$_GS_TEST_BUCKET/_test/$(uuid4())"
        config = HiveConfiguration(hive_location = test_prefix, filesystem = "gs")
        try
            source = DataSource(
                "DISPATCHPRICE", ["SETTLEMENTDATE", "REGIONID", "RRP"], config;
                table_sort_by = ["SETTLEMENTDATE", "REGIONID"],
            )
            @test source.path == "gs://$test_prefix/DISPATCHPRICE"
            @test source.filesystem == "gs"

            # cached_date_range is not exported by either module — call it
            # fully-qualified, same as _add_data/_partition_has_data elsewhere
            # in this file.
            cached_date_range = AustralianElectricityMarkets.AustralianElectricityMarketsData.cached_date_range

            # cached_date_range on a not-yet-written remote source: no data yet.
            @test cached_date_range(source) === nothing

            # populate() with force_new will attempt a real NEMWEB download for a
            # known-good historical month, then write straight to GS via COPY.
            date_range = Date(2024, 1, 1):Month(1):Date(2024, 1, 1)
            populate(source, date_range)

            # If NEMWEB had the file (network permitting), the partition should now
            # be visible via the same remote existence-check path used by populate.
            range = cached_date_range(source)
            if range !== nothing
                @test range == (Date(2024, 1, 1), Date(2024, 1, 31))

                # populate again — should skip (data_exists) rather than re-fetch.
                @test_logs (:info, r"already exists") min_level = Logging.Info match_mode = :any populate(source, date_range)
            end
        finally
            run(`gcloud storage rm -r gs://$test_prefix`)
        end
    end
end
```

- [ ] **Step 3: Run the test against the real bucket**

Run: `julia --project=. -e 'using Test, AustralianElectricityMarkets; include("test/test-nemweb-load.jl")'`

This is a live-cloud test — expect to iterate here. Specifically verify:

- The `glob('gs://.../*/ ')`-based `_partition_dir_names` pattern from Task 6 actually returns what's expected against real GCS output (directory entries may come back with or without a trailing slash, or as full `gs://...` paths rather than bare names — adjust the `basename(rstrip(f, '/'))` parsing in `_partition_dir_names` if real GCS `glob()` output doesn't match what local-filesystem testing simulated).
- `gcloud storage rm -r gs://$test_prefix` actually deletes the test prefix (check via `gcloud storage ls gs://$_GS_TEST_BUCKET/_test/` after a run — it should be empty or absent).
- If NEMWEB's historical archive doesn't actually have a `DISPATCHPRICE` file for 2024-01 by the time this runs, `populate` will hit `MissingDataError` and log `"No data available"` — that's an acceptable outcome for this test (it's the download step failing, not the remote-write path), but the write-side assertions (`source.path`, `source.filesystem`, initial `cached_date_range === nothing`) must still hold. If you hit this, pick any table/month combination confirmed present via `_TABLE_SPECS` and NEMWEB's public archive listing rather than hardcoding a month that may not exist.

Expected: PASS end to end, including cleanup leaving no residual objects under the test prefix.

- [ ] **Step 4: Run the full test suite one more time**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: PASS across the board — this is the final check that nothing in Tasks 1-7 regressed any other test file (`datareader.jl`, `isp_data.jl`, `regionmodel.jl`, `timeseries_setters.jl`, `aqua.jl`).

- [ ] **Step 5: Commit**

```bash
git add test/Project.toml test/test-nemweb-load.jl
git commit -m "Add end-to-end remote-write test against gs://australian_electricity_markets"
```
