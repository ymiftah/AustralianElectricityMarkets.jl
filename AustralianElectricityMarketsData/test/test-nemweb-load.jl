using AustralianElectricityMarketsData: HiveConfiguration
using AustralianElectricityMarketsData:
    DataSource, get_table, MissingDataError, _TABLE_SPECS, ARCHIVE_MONTH_PARTITION,
    _extract_d_lines, _csv_to_parquet, _new_duckdb_connection
using DataFrames, Dates, Logging, ZipFile, DuckDB, DBInterface

# ══════════════════════════════════════════════════════════════════════════════
# Fixtures — minimal NEMWEB-format files
# ══════════════════════════════════════════════════════════════════════════════

"""
Build a minimal real-shaped NEMWEB CSV (plain file, not zipped) and return the
temp path. Caller is responsible for deleting the returned file.
"""
function make_nemweb_csv(table_name, cols, rows)
    # AEMO's MMS CSV format always has a fixed 4-field prefix on I/D records
    # (record_type, namespace, report, version) before the real columns —
    # confirmed against real downloaded files (e.g.
    # `I,DISPATCH,REGIONSUM,9,SETTLEMENTDATE,...`,
    # `I,PARTICIPANT_REGISTRATION,STATION,1,STATIONID,...`).
    tmp = tempname() * ".csv"
    open(tmp, "w") do io
        println(io, "C,SETP.WORLD,DVD_$table_name,AEMO,PUBLIC,2026/06/01,00:00:00,1,MONTHLY_ARCHIVE,1")
        println(io, "I,TEST,$table_name,1," * join(string.(cols), ","))
        for r in rows
            println(io, "D,TEST,$table_name,1," * join(string.(r), ","))
        end
        println(io, "C,\"END OF REPORT\",$(length(rows) + 3)")
    end
    return tmp
end

function make_empty_zip()
    tmp = tempname() * ".zip"
    w = ZipFile.Writer(tmp)
    close(w)
    return tmp
end

function make_zip_no_csv()
    tmp = tempname() * ".zip"
    w = ZipFile.Writer(tmp)
    f = ZipFile.addfile(w, "data.txt")
    write(f, "some text\n")
    close(w)
    return tmp
end

function make_zip_with_csv(csv_path::String)
    tmp = tempname() * ".zip"
    w = ZipFile.Writer(tmp)
    f = ZipFile.addfile(w, basename(csv_path))
    write(f, read(csv_path))
    close(w)
    return tmp
end

"""
Read just the NEMWEB "I" record (line 2) of a plain (non-zipped) fixture CSV
to learn its real column names/order — the same information `_extract_d_lines`
captures inline when reading from a ZIP.
"""
_peek_header_columns(csv_path) =
    open(csv_path) do io
    readline(io)                        # C record
    fields = split(readline(io), ",")   # I: I, namespace, report, version, col1, col2, ...
    String.(strip.(fields[5:end]))
end

"""
Read a Hive-partitioned parquet dataset back into a DataFrame, to check what
`_csv_to_parquet` actually wrote.
"""
function _read_parquet_file(parquet_path)
    conn = _new_duckdb_connection()
    try
        return DBInterface.execute(conn, "SELECT * FROM read_parquet('$parquet_path', hive_partitioning=true)") |> DataFrame
    finally
        DBInterface.close!(conn)
    end
end

_run_csv_to_parquet(csv_path, table_columns, out_path; sort_by = String[], year = 2024, month = 1) =
let conn = DuckDB.DB()
    try
        available_cols = _peek_header_columns(csv_path)
        _csv_to_parquet(conn, csv_path, available_cols, table_columns, out_path, [ARCHIVE_MONTH_PARTITION], sort_by, year, month)
    finally
        DBInterface.close!(conn)
    end
end


# ══════════════════════════════════════════════════════════════════════════════
# A0. Download failure classification — absence vs. rate limiting
# ══════════════════════════════════════════════════════════════════════════════

@testset "_is_transient_status: separates 'ask again later' from 'does not exist'" begin
    # 403 is the important one: NEMWEB rate-limits with it, and a bulk populate over a wide
    # date range trips that easily. Classifying it as absence is what silently holes a cache.
    for s in (403, 408, 425, 429, 500, 502, 503, 504)
        @test AustralianElectricityMarketsData._is_transient_status(s)
    end
    # 404 is the only status that actually means AEMO never published the month.
    @test !AustralianElectricityMarketsData._is_transient_status(404)
    for s in (200, 301, 400, 401, 410)
        @test !AustralianElectricityMarketsData._is_transient_status(s)
    end
end

@testset "MissingDataError and TransientDownloadError are distinct types" begin
    # populate skips MissingDataError and must NOT skip TransientDownloadError; if one were
    # a subtype of the other, `isa` in _add_data's catch would silently swallow both.
    miss = AustralianElectricityMarketsData.MissingDataError("gone")
    transient = AustralianElectricityMarketsData.TransientDownloadError("throttled")
    @test miss isa Exception
    @test transient isa Exception
    @test !(transient isa AustralianElectricityMarketsData.MissingDataError)
    @test !(miss isa AustralianElectricityMarketsData.TransientDownloadError)
end

# ══════════════════════════════════════════════════════════════════════════════
# A. _extract_d_lines — ZIP handling + D-line filtering + header capture
# ══════════════════════════════════════════════════════════════════════════════

@testset "_extract_d_lines: keeps only D records, in original order, and captures columns" begin
    csv_path = make_nemweb_csv("DISPATCHPRICE", ["REGIONID", "RRP"], [("NSW1", "1.0"), ("VIC1", "2.0"), ("QLD1", "3.0")])
    zip_path = make_zip_with_csv(csv_path)
    try
        d_path, available_cols = _extract_d_lines(zip_path)
        try
            @test available_cols == ["REGIONID", "RRP"]
            lines = readlines(d_path)
            @test length(lines) == 3
            @test all(startswith(l, "D,") for l in lines)
            @test occursin("NSW1", lines[1]) && occursin("VIC1", lines[2]) && occursin("QLD1", lines[3])
        finally
            isfile(d_path) && rm(d_path)
        end
    finally
        isfile(csv_path) && rm(csv_path)
        isfile(zip_path) && rm(zip_path)
    end
end

@testset "_extract_d_lines: empty ZIP throws MissingDataError" begin
    zip_path = make_empty_zip()
    try
        @test_throws MissingDataError _extract_d_lines(zip_path)
    finally
        isfile(zip_path) && rm(zip_path)
    end
end

@testset "_extract_d_lines: ZIP with no .csv entry throws MissingDataError" begin
    zip_path = make_zip_no_csv()
    try
        @test_throws MissingDataError _extract_d_lines(zip_path)
    finally
        isfile(zip_path) && rm(zip_path)
    end
end


# ══════════════════════════════════════════════════════════════════════════════
# B. _csv_to_parquet — CSV → Parquet entirely inside DuckDB
# ══════════════════════════════════════════════════════════════════════════════

@testset "_csv_to_parquet: reads data rows, casts types, filters non-D records" begin
    csv_path = make_nemweb_csv(
        "DISPATCHPRICE",
        ["SETTLEMENTDATE", "REGIONID", "RRP"],
        [
            ("2024/01/15 05:00:00", "NSW1", "100.5"),
            ("2024/01/15 05:05:00", "VIC1", "98.3"),
            ("2024/01/15 05:10:00", "QLD1", "102.1"),
        ],
    )
    tmpdir = mktempdir()
    try
        _run_csv_to_parquet(csv_path, ["SETTLEMENTDATE", "REGIONID", "RRP"], tmpdir)
        df = sort(_read_parquet_file(tmpdir), :REGIONID)
        @test nrow(df) == 3
        @test df.REGIONID == ["NSW1", "QLD1", "VIC1"]
        row = df[df.REGIONID .== "NSW1", :]
        @test row.SETTLEMENTDATE[1] == DateTime(2024, 1, 15, 5, 0, 0)
        @test row.RRP[1] ≈ 100.5
    finally
        isfile(csv_path) && rm(csv_path)
    end
end

@testset "_csv_to_parquet: columns absent from the file become typed NULL" begin
    csv_path = make_nemweb_csv("DISPATCHPRICE", ["SETTLEMENTDATE", "REGIONID"], [("2024/01/15 05:00:00", "NSW1")])
    tmpdir = mktempdir()
    try
        _run_csv_to_parquet(csv_path, ["SETTLEMENTDATE", "REGIONID", "RRP"], tmpdir)
        df = _read_parquet_file(tmpdir)
        @test "RRP" in names(df)
        @test ismissing(df.RRP[1])
        @test eltype(df.RRP) <: Union{Missing, Float32}
    finally
        isfile(csv_path) && rm(csv_path)
    end
end

@testset "_csv_to_parquet: extra columns in the file are ignored" begin
    csv_path = make_nemweb_csv(
        "DISPATCHPRICE", ["SETTLEMENTDATE", "REGIONID", "RRP", "EXTRA_COL"],
        [("2024/01/15 05:00:00", "NSW1", "100.5", "ignored")],
    )
    tmpdir = mktempdir()
    try
        _run_csv_to_parquet(csv_path, ["SETTLEMENTDATE", "REGIONID", "RRP"], tmpdir)
        df = _read_parquet_file(tmpdir)
        @test !("EXTRA_COL" in names(df))
        @test nrow(df) == 1
    finally
        isfile(csv_path) && rm(csv_path)
    end
end

@testset "_csv_to_parquet: a column empty on every row becomes typed NULL, not a crash" begin
    # Regression test: a real column present in the header but empty on every D
    # row previously made CSV.jl infer a bare-Missing (`Union{}`) column, which
    # the old DataFrame-based write path's DuckDB registration couldn't map —
    # crashing the write. The DuckDB-native pipeline reads everything as
    # VARCHAR and TRY_CASTs, so an all-empty numeric column just becomes
    # all-NULL.
    csv_path = make_nemweb_csv(
        "DISPATCHPRICE", ["SETTLEMENTDATE", "REGIONID", "RRP"],
        [("2024/01/15 05:00:00", "NSW1", ""), ("2024/01/15 05:05:00", "VIC1", "")],
    )
    tmpdir = mktempdir()
    try
        _run_csv_to_parquet(csv_path, ["SETTLEMENTDATE", "REGIONID", "RRP"], tmpdir)
        df = _read_parquet_file(tmpdir)
        @test nrow(df) == 2
        @test all(ismissing, df.RRP)
        @test eltype(df.RRP) <: Union{Missing, Float32}
    finally
        isfile(csv_path) && rm(csv_path)
    end
end

@testset "_csv_to_parquet: header/trailer of different width than data rows are excluded" begin
    # make_nemweb_csv's C header (10 fields) and trailer (3 fields) are already
    # narrower than the D/I rows here (7 fields) — this is the real-world shape
    # confirmed against a live NEMWEB file, not position-based (skip-N-lines).
    csv_path = make_nemweb_csv("DISPATCHPRICE", ["REGIONID", "RRP"], [("NSW1", "100.5")])
    tmpdir = mktempdir()
    try
        _run_csv_to_parquet(csv_path, ["REGIONID", "RRP"], tmpdir)
        df = _read_parquet_file(tmpdir)
        @test nrow(df) == 1
        @test df.REGIONID[1] == "NSW1"
    finally
        isfile(csv_path) && rm(csv_path)
    end
end

@testset "_csv_to_parquet: many rows survive intact (no chunk boundary to lose data across)" begin
    n = 5_000
    rows = [("NSW1", string(100.0 + i)) for i in 1:n]
    csv_path = make_nemweb_csv("DISPATCHPRICE", ["REGIONID", "RRP"], rows)
    tmpdir = mktempdir()
    try
        _run_csv_to_parquet(csv_path, ["REGIONID", "RRP"], tmpdir)
        df = _read_parquet_file(tmpdir)
        @test nrow(df) == n
    finally
        isfile(csv_path) && rm(csv_path)
    end
end

@testset "_csv_to_parquet: tags rows with the requested archive_month" begin
    csv_path = make_nemweb_csv("DISPATCHPRICE", ["REGIONID", "RRP"], [("NSW1", "100.5")])
    tmpdir = mktempdir()
    try
        _run_csv_to_parquet(csv_path, ["REGIONID", "RRP"], tmpdir; year = 2024, month = 3)
        @test isdir(joinpath(tmpdir, "archive_month=2024-03-01"))
    finally
        isfile(csv_path) && rm(csv_path)
    end
end

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

# ══════════════════════════════════════════════════════════════════════════════
# A2. islocal / _parse_hive_root — shared local-vs-remote path logic
# ══════════════════════════════════════════════════════════════════════════════

@testset "islocal(filesystem::String): true only for \"file\"" begin
    @test AustralianElectricityMarketsData.islocal("file")
    @test !AustralianElectricityMarketsData.islocal("s3")
    @test !AustralianElectricityMarketsData.islocal("gs")
end

@testset "islocal(config): delegates to islocal(filesystem)" begin
    @test AustralianElectricityMarketsData.islocal(HiveConfiguration(filesystem = "file"))
    @test !AustralianElectricityMarketsData.islocal(HiveConfiguration(filesystem = "s3"))
end

@testset "_parse_hive_root: local returns hive_location, remote returns scheme://hive_location" begin
    @test AustralianElectricityMarketsData._parse_hive_root(HiveConfiguration(hive_location = "/tmp/x", filesystem = "file")) == "/tmp/x"
    @test AustralianElectricityMarketsData._parse_hive_root(HiveConfiguration(hive_location = "bucket/prefix", filesystem = "gs")) == "gs://bucket/prefix"
    @test AustralianElectricityMarketsData._parse_hive_root(HiveConfiguration(hive_location = "bucket/prefix", filesystem = "s3")) == "s3://bucket/prefix"
end

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


# ══════════════════════════════════════════════════════════════════════════════
# D. DataSource construction — pure, no filesystem side effects
# ══════════════════════════════════════════════════════════════════════════════

@testset "DataSource: fields are assigned correctly" begin
    tmpdir = mktempdir()
    source = DataSource(
        "DISPATCHPRICE",
        ["SETTLEMENTDATE", "REGIONID", "RRP"],
        HiveConfiguration(hive_location = tmpdir);
        table_sort_by = ["SETTLEMENTDATE", "REGIONID"],
    )
    @test source.table_name == "DISPATCHPRICE"
    @test source.table_columns == ["SETTLEMENTDATE", "REGIONID", "RRP"]
    @test source.table_sort_by == ["SETTLEMENTDATE", "REGIONID"]
end

@testset "DataSource: partitions always end with archive_month" begin
    tmpdir = mktempdir()
    config = HiveConfiguration(hive_location = tmpdir)
    s1 = DataSource("T", ["C"], config)
    @test s1.partitions == [ARCHIVE_MONTH_PARTITION]

    s2 = DataSource("T", ["C"], config; add_partitions = ["REGIONID"])
    @test s2.partitions == ["REGIONID", ARCHIVE_MONTH_PARTITION]
    @test last(s2.partitions) == ARCHIVE_MONTH_PARTITION
end

@testset "DataSource: path is joinpath(hive_location, table_name), construction touches no filesystem" begin
    tmpdir = mktempdir()
    source = DataSource("MY_TABLE", ["COL1"], HiveConfiguration(hive_location = tmpdir))
    @test source.path == joinpath(tmpdir, "MY_TABLE")
    @test !isdir(source.path)  # construction is pure — the write path creates it lazily
end

@testset "DataSource: accepts a remote HiveConfiguration and builds a scheme:// path" begin
    config = HiveConfiguration(hive_location = "bucket/path", filesystem = "s3")
    source = DataSource("T", ["C"], config)
    @test source.path == "s3://bucket/path/T"
    @test AustralianElectricityMarketsData.get_filesystem(source) == "s3"
    @test !AustralianElectricityMarketsData.islocal(source)
end

@testset "DataSource: filesystem is derived from path's scheme for local sources" begin
    tmpdir = mktempdir()
    source = DataSource("T", ["C"], HiveConfiguration(hive_location = tmpdir))
    @test AustralianElectricityMarketsData.get_filesystem(source) == "file"
    @test AustralianElectricityMarketsData.islocal(source)
end


# ══════════════════════════════════════════════════════════════════════════════
# E. get_table / list_available_tables — AEMDB-based lookup, no manager/global state
# ══════════════════════════════════════════════════════════════════════════════

@testset "list_available_tables: matches _TABLE_SPECS names" begin
    @test Set(list_available_tables()) == Set(getfield.(collect(_TABLE_SPECS), :name))
end

@testset "get_table: returns DataSource with correct table_name for every _TABLE_SPECS entry" begin
    tmpdir = mktempdir()
    db = aem_connect(HiveConfiguration(hive_location = tmpdir))
    for spec in _TABLE_SPECS
        source = get_table(db, Symbol(spec.name))
        @test source isa DataSource
        @test source.table_name == spec.name
        @test source.path == joinpath(tmpdir, spec.name)
    end
end

@testset "get_table: throws ArgumentError with table name in message for unknown symbol" begin
    tmpdir = mktempdir()
    db = aem_connect(HiveConfiguration(hive_location = tmpdir))
    try
        get_table(db, :NONEXISTENT_TABLE)
        @test false  # Must not reach here
    catch e
        @test e isa ArgumentError
        @test occursin("NONEXISTENT_TABLE", e.msg)
    end
end


@testset "_partition_has_data: local — true iff dir exists and has a .parquet file" begin
    tmpdir = mktempdir()
    source = DataSource("T", ["C"], HiveConfiguration(hive_location = tmpdir))
    partition_dir = joinpath(tmpdir, "T", "archive_month=2024-01-01")

    @test !AustralianElectricityMarketsData._partition_has_data(source, partition_dir)

    mkpath(partition_dir)
    @test !AustralianElectricityMarketsData._partition_has_data(source, partition_dir)  # dir exists, no parquet yet

    write(joinpath(partition_dir, "data.parquet"), UInt8[])
    @test AustralianElectricityMarketsData._partition_has_data(source, partition_dir)
end

@testset "_partition_dir_names: local — matches readdir on source.path" begin
    tmpdir = mktempdir()
    source = DataSource("T", ["C"], HiveConfiguration(hive_location = tmpdir))
    mkpath(joinpath(source.path, "archive_month=2024-01-01"))
    mkpath(joinpath(source.path, "archive_month=2024-02-01"))
    @test Set(AustralianElectricityMarketsData._partition_dir_names(source)) ==
        Set(["archive_month=2024-01-01", "archive_month=2024-02-01"])
end

# ══════════════════════════════════════════════════════════════════════════════
# F. populate(::DataSource, ...) — skip-existing logic
# ══════════════════════════════════════════════════════════════════════════════

@testset "populate: skips download when Hive partition already exists" begin
    tmpdir = mktempdir()
    source = DataSource("DISPATCHPRICE", ["SETTLEMENTDATE", "REGIONID", "RRP"], HiveConfiguration(hive_location = tmpdir))

    partition_dir = joinpath(source.path, "archive_month=2024-01-01")
    mkpath(partition_dir)
    stub = joinpath(partition_dir, "data.parquet")
    write(stub, UInt8[])  # zero-byte stub stands in for real parquet

    date_range = Date(2024, 1, 1):Month(1):Date(2024, 1, 1)
    @test_logs (:info, r"already exists") min_level = Logging.Info match_mode = :any populate(source, date_range)
    @test isfile(stub)  # stub untouched — no download occurred
end

@testset "populate: force_new=true overrides existing partition and attempts download" begin
    tmpdir = mktempdir()
    source = DataSource("DISPATCHPRICE", ["SETTLEMENTDATE", "REGIONID", "RRP"], HiveConfiguration(hive_location = tmpdir))

    partition_dir = joinpath(source.path, "archive_month=2024-01-01")
    mkpath(partition_dir)
    write(joinpath(partition_dir, "data.parquet"), UInt8[])

    date_range = Date(2024, 1, 1):Month(1):Date(2024, 1, 1)
    # force_new triggers fetch — "Fetching data" log appears regardless of what
    # the actual download does next (succeeds, or fails gracefully via MissingDataError)
    @test_logs (:info, r"Fetching data") min_level = Logging.Info match_mode = :any populate(source, date_range; force_new = true)
end

@testset "_clear_local_partition: removes an existing partition dir for a local source" begin
    tmpdir = mktempdir()
    source = DataSource("T", ["C"], HiveConfiguration(hive_location = tmpdir))
    partition_dir = joinpath(tmpdir, "archive_month=2024-01-01")
    mkpath(partition_dir)
    write(joinpath(partition_dir, "data.parquet"), UInt8[])

    AustralianElectricityMarketsData._clear_local_partition(source, partition_dir)
    @test !isdir(partition_dir)
end

@testset "_clear_local_partition: leaves the directory untouched for a remote source" begin
    # `source.path` (gs://...) is unrelated to `partition_dir` — the function only
    # reads source's scheme to decide whether to touch the directory it's given.
    remote_source = DataSource("T", ["C"], HiveConfiguration(hive_location = "bucket/path", filesystem = "gs"))
    tmpdir = mktempdir()
    partition_dir = joinpath(tmpdir, "archive_month=2024-01-01")
    mkpath(partition_dir)
    sentinel = joinpath(partition_dir, "sentinel.parquet")
    write(sentinel, UInt8[1, 2, 3])

    AustralianElectricityMarketsData._clear_local_partition(remote_source, partition_dir)
    @test isfile(sentinel)
end


# ══════════════════════════════════════════════════════════════════════════════
# G. populate(::AEMDB, ...) — the same struct used for both write and read
# ══════════════════════════════════════════════════════════════════════════════

@testset "populate(::AEMDB, table_name, ...): resolves to the right DataSource and skips existing data" begin
    tmpdir = mktempdir()
    db = aem_connect(HiveConfiguration(hive_location = tmpdir))

    partition_dir = joinpath(tmpdir, "DISPATCHPRICE", "archive_month=2024-01-01")
    mkpath(partition_dir)
    write(joinpath(partition_dir, "data.parquet"), UInt8[])

    # Would previously hit the `getfield(manager, Symbol(table_name))` bug when
    # called through the 2-arg NEMWEBManager overload; here there is no manager
    # at all — `populate(::AEMDB, ...)` looks the table up via `get_table`.
    @test_logs (:info, r"already exists") min_level = Logging.Info match_mode = :any populate(
        db, :DISPATCHPRICE, Date(2024, 1, 1), Date(2024, 1, 1)
    )
end

@testset "populate(::AEMDB, start, end; tables): only the requested tables are processed" begin
    tmpdir = mktempdir()
    db = aem_connect(HiveConfiguration(hive_location = tmpdir))
    for table in ("DISPATCHPRICE", "DISPATCHLOAD")
        partition_dir = joinpath(tmpdir, table, "archive_month=2024-01-01")
        mkpath(partition_dir)
        write(joinpath(partition_dir, "data.parquet"), UInt8[])
    end

    logs, _ = Test.collect_test_logs() do
        populate(db, Date(2024, 1, 1), Date(2024, 1, 1); tables = [:DISPATCHPRICE])
    end
    processed = [l.kwargs[:table] for l in logs if l.message == "Processing table"]
    @test processed == [:DISPATCHPRICE]
end

@testset "show(::AEMDB): compact form reports hive_location and filesystem" begin
    tmpdir = mktempdir()
    db = aem_connect(HiveConfiguration(hive_location = tmpdir))
    @test sprint(show, db) == "AEMDB(hive_location=\"$tmpdir\", filesystem=\"file\")"
end

@testset "show(::AEMDB, MIME\"text/plain\"): lists every table with its cached date range" begin
    tmpdir = mktempdir()
    db = aem_connect(HiveConfiguration(hive_location = tmpdir))
    partition_dir = joinpath(tmpdir, "DISPATCHPRICE", "archive_month=2024-01-01")
    mkpath(partition_dir)
    write(joinpath(partition_dir, "data.parquet"), UInt8[])

    output = sprint(io -> show(io, MIME("text/plain"), db))
    @test occursin("DISPATCHPRICE", output)
    @test occursin("2024-01-01 … 2024-01-31", output)
    @test occursin("DISPATCHLOAD", output)
    @test occursin("(not cached)", output)
end


using UUIDs: uuid4

# ══════════════════════════════════════════════════════════════════════════════
# H. Remote (GS) end-to-end — real bucket, skipped if unreachable
# ══════════════════════════════════════════════════════════════════════════════

const _GS_TEST_BUCKET = "australian_electricity_markets"

function _gs_test_reachable()
    conn = nothing
    try
        conn = _new_duckdb_connection("gs")
        DBInterface.execute(conn, "SELECT COUNT(*) FROM glob('gs://$_GS_TEST_BUCKET/*')")
        return true
    catch e
        @info "Skipping GS end-to-end tests — bucket unreachable/uncredentialed" exception = e
        return false
    finally
        conn === nothing || DBInterface.close!(conn)
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
            @test AustralianElectricityMarketsData.get_filesystem(source) == "gs"

            # cached_date_range is not exported by either module — call it
            # fully-qualified, same as _add_data/_partition_has_data elsewhere
            # in this file.
            cached_date_range = AustralianElectricityMarketsData.cached_date_range

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
