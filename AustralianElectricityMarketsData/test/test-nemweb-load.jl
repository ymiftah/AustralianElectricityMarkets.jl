using AustralianElectricityMarketsData: HiveConfiguration
using AustralianElectricityMarketsData:
    DataSource, get_table, MissingDataError, TransientDownloadError, _TABLE_SPECS, ARCHIVE_MONTH_PARTITION,
    _extract_d_lines, _csv_to_parquet, _new_duckdb_connection, _get_archive, NEMWEB_URL, NEMWEB_URL_ALT,
    _month_filter_bounds, _csv_field, _fetch_with_retry, _download_and_cache
using DataFrames, Dates, Logging, ZipFile, DuckDB, DBInterface, HTTP, Test

# A minimal NEMWEB CSV (plain, not zipped) at a temp path. I and D records carry AEMO's fixed
# 4-field prefix (record type, namespace, report, version) before the columns.
function make_nemweb_csv(table_name, cols, rows)
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

# The column names of a plain fixture CSV's I record (line 2), as `_extract_d_lines` captures them from a ZIP.
_peek_header_columns(csv_path) =
    open(csv_path) do io
    readline(io)                        # C record
    fields = split(readline(io), ",")   # I: I, namespace, report, version, col1, col2, ...
    String.(strip.(fields[5:end]))
end

# A Hive-partitioned parquet dataset read back into a DataFrame.
function _read_parquet_file(parquet_path)
    conn = _new_duckdb_connection()
    try
        return DBInterface.execute(conn, "SELECT * FROM read_parquet('$parquet_path', hive_partitioning=true)") |> DataFrame
    finally
        DBInterface.close!(conn)
    end
end

_run_csv_to_parquet(
    csv_path, table_columns, out_path;
    sort_by = String[], year = 2024, month = 1, month_filter_column = nothing, row_filter = nothing,
) =
let conn = DuckDB.DB()
    try
        available_cols = _peek_header_columns(csv_path)
        _csv_to_parquet(
            conn, csv_path, available_cols, table_columns, out_path, [ARCHIVE_MONTH_PARTITION], sort_by, year, month;
            month_filter_column, row_filter,
        )
    finally
        DBInterface.close!(conn)
    end
end

# The primary and ALT URLs `_get_archive` builds for a table, month and part.
_primary_url(table, year, month) = replace(
    NEMWEB_URL, "{year}" => year, "{month:02d}" => lpad(month, 2, '0'), "{table}" => table,
)
_alt_url(table, year, month, part) = replace(
    NEMWEB_URL_ALT, "{year}" => year, "{month:02d}" => lpad(month, 2, '0'), "{table}" => table,
    "{part:02d}" => lpad(part, 2, '0'),
)

@testset "_is_transient_status: separates 'ask again later' from 'does not exist'" begin
    # NEMWEB rate-limits with 403; only 404 means AEMO never published the month.
    @test all(AustralianElectricityMarketsData._is_transient_status, (403, 408, 425, 429, 500, 502, 503, 504))
    @test !any(AustralianElectricityMarketsData._is_transient_status, (404, 200, 301, 400, 401, 410))
end

@testset "_get_archive: single-part: primary URL succeeds, ALT never attempted" begin
    table, year, month = "T", 2024, 1
    primary = _primary_url(table, year, month)
    calls = String[]
    download!(url, cache_path) = begin
        push!(calls, url)
        url == primary || error("unexpected url $url")
        write(cache_path, UInt8[1])
        return nothing
    end
    zip_paths = _get_archive(table, year, month; download! = download!)
    try
        @test length(zip_paths) == 1
        @test isfile(only(zip_paths))
        @test calls == [primary]
    finally
        foreach(p -> rm(p; force = true), zip_paths)
    end
end

@testset "_get_archive: multi-part: FILE01+FILE02 present, FILE03 404, both parts loaded" begin
    table, year, month = "T", 2026, 6
    primary = _primary_url(table, year, month)
    alt1, alt2, alt3 = (_alt_url(table, year, month, p) for p in 1:3)
    calls = String[]
    download!(url, cache_path) = begin
        push!(calls, url)
        if url == primary || url == alt3
            throw(MissingDataError("404: $url"))
        elseif url in (alt1, alt2)
            write(cache_path, UInt8[1])
            return nothing
        else
            error("unexpected url $url")
        end
    end
    zip_paths = _get_archive(table, year, month; download! = download!)
    try
        @test length(zip_paths) == 2
        @test all(isfile, zip_paths)
        @test calls == [primary, alt1, alt2, alt3]  # stopped as soon as FILE03 404'd
    finally
        foreach(p -> rm(p; force = true), zip_paths)
    end
end

@testset "_get_archive: primary and FILE01 both 404: combined MissingDataError, no files left behind" begin
    table, year, month = "T", 2024, 1
    download!(url, cache_path) = throw(MissingDataError("404: $url"))
    @test_throws MissingDataError _get_archive(table, year, month; download! = download!)
end

@testset "_get_archive: transient error on FILE02 propagates rather than ending the part loop" begin
    table, year, month = "T", 2024, 1
    primary = _primary_url(table, year, month)
    alt1, alt2 = (_alt_url(table, year, month, p) for p in 1:2)
    written = String[]
    download!(url, cache_path) = begin
        if url == primary
            throw(MissingDataError("404: $url"))
        elseif url == alt1
            write(cache_path, UInt8[1])
            push!(written, cache_path)
            return nothing
        elseif url == alt2
            throw(TransientDownloadError("rate limited: $url"))
        else
            error("unexpected url $url")
        end
    end
    @test_throws TransientDownloadError _get_archive(table, year, month; download! = download!)
    # FILE01's zip is cleaned up on the way out, not leaked for a caller who never sees it.
    @test !any(isfile, written)
end

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

@testset "_extract_d_lines: an empty ZIP or one with no .csv entry throws MissingDataError" begin
    for zip_path in (make_empty_zip(), make_zip_no_csv())
        @test_throws MissingDataError _extract_d_lines(zip_path)
        rm(zip_path)
    end
end

@testset "_extract_d_lines: cleans up its temp CSV when it errors after partially writing" begin
    # D lines with no I record: the temp file is written, then the missing-header check throws.
    tmp = tempname() * ".csv"
    open(tmp, "w") do io
        println(io, "D,TEST,DISPATCHPRICE,1,NSW1,1.0")
    end
    zip_path = make_zip_with_csv(tmp)
    tmp_dir = AustralianElectricityMarketsData._local_tmp_dir()
    before = Set(readdir(tmp_dir))
    try
        @test_throws MissingDataError _extract_d_lines(zip_path)
        @test Set(readdir(tmp_dir)) == before
    finally
        foreach(p -> isfile(p) && rm(p), (tmp, zip_path))
    end
end

@testset "_extract_d_lines(::Vector): concatenates every part's D lines, in order, using the first part's columns" begin
    csv1 = make_nemweb_csv("DISPATCHPRICE", ["REGIONID", "RRP"], [("NSW1", "1.0"), ("VIC1", "2.0")])
    csv2 = make_nemweb_csv("DISPATCHPRICE", ["REGIONID", "RRP"], [("QLD1", "3.0")])
    zip1, zip2 = make_zip_with_csv(csv1), make_zip_with_csv(csv2)
    try
        d_path, available_cols = _extract_d_lines([zip1, zip2])
        try
            @test available_cols == ["REGIONID", "RRP"]
            lines = readlines(d_path)
            @test length(lines) == 3
            @test occursin("NSW1", lines[1]) && occursin("VIC1", lines[2]) && occursin("QLD1", lines[3])
        finally
            isfile(d_path) && rm(d_path)
        end
    finally
        foreach(p -> isfile(p) && rm(p), (csv1, csv2, zip1, zip2))
    end
end

@testset "_extract_d_lines(::Vector): cleans up the combined temp CSV when a later part fails" begin
    csv1 = make_nemweb_csv("DISPATCHPRICE", ["REGIONID", "RRP"], [("NSW1", "1.0")])
    zip1 = make_zip_with_csv(csv1)
    zip2 = make_zip_no_csv()  # second part fails, after the first part's bytes are already combined
    tmp_dir = AustralianElectricityMarketsData._local_tmp_dir()
    before = Set(readdir(tmp_dir))
    try
        @test_throws MissingDataError _extract_d_lines([zip1, zip2])
        @test Set(readdir(tmp_dir)) == before  # no leaked combined-CSV temp file
    finally
        foreach(p -> isfile(p) && rm(p), (csv1, zip1, zip2))
    end
end

@testset "_extract_d_lines(::Vector): throws when a later part's columns differ from the first part's" begin
    csv1 = make_nemweb_csv("DISPATCHPRICE", ["REGIONID", "RRP"], [("NSW1", "1.0")])
    csv2 = make_nemweb_csv("DISPATCHPRICE", ["REGIONID", "RRP", "EXTRA"], [("VIC1", "2.0", "9")])
    zip1, zip2 = make_zip_with_csv(csv1), make_zip_with_csv(csv2)
    tmp_dir = AustralianElectricityMarketsData._local_tmp_dir()
    before = Set(readdir(tmp_dir))
    try
        @test_throws ArgumentError _extract_d_lines([zip1, zip2])
        @test Set(readdir(tmp_dir)) == before
    finally
        foreach(p -> isfile(p) && rm(p), (csv1, csv2, zip1, zip2))
    end
end

# Interval-ending stamps around June 2026: an interval ending at 00:00 on the 1st belongs to the previous month.
const MONTH_FILTER_ROWS = [
    ("2026/05/31 23:55:00", "PREV"), ("2026/06/01 00:00:00", "PREV_BOUNDARY"), ("2026/06/01 00:05:00", "FIRST"),
    ("2026/06/30 23:55:00", "LAST"), ("2026/07/01 00:00:00", "NEXT_BOUNDARY"), ("2026/07/01 00:05:00", "NEXT"),
]

@testset "_month_filter_bounds: lower is exclusive first-of-month, upper is inclusive first-of-next-month" begin
    @test _month_filter_bounds(2026, 6) == ("2026/06/01 00:00:00", "2026/07/01 00:00:00")
    @test _month_filter_bounds(2026, 12) == ("2026/12/01 00:00:00", "2027/01/01 00:00:00")
end

@testset "_csv_field: picks one field, strips quotes, and honours commas inside quotes" begin
    line = "D,TEST,T,1,\"2026/06/01 00:05:00\",\"a, b\",plain,"
    @test _csv_field(line, 1) == "D"
    @test _csv_field(line, 5) == "2026/06/01 00:05:00"
    @test _csv_field(line, 6) == "a, b"
    @test _csv_field(line, 7) == "plain"
    @test _csv_field(line, 8) == ""
    @test _csv_field(line, 5) isa SubString{String}
    @test_throws ArgumentError _csv_field(line, 9)
    # A comma-bearing quoted field before the target must not shift the field index.
    @test _csv_field("D,T,T,1,\"x,y\",\"2026/06/01 00:05:00\"", 6) == "2026/06/01 00:05:00"
end

@testset "_extract_d_lines: month filter reads the right field past quoted commas and ignores fractional seconds" begin
    rows = [
        ("\"note, with comma\"", "2026/06/01 00:00:00.000", "BOUNDARY_FRACTION"),
        ("\"note\"", "2026/06/01 00:05:00.000", "IN"),
    ]
    csv_path = make_nemweb_csv("T", ["NOTE", "INTERVAL_DATETIME", "ID"], rows)
    zip_path = make_zip_with_csv(csv_path)
    lo, hi = _month_filter_bounds(2026, 6)
    try
        d_path, _ = _extract_d_lines(zip_path; month_filter_column = "INTERVAL_DATETIME", lo, hi)
        try
            @test [split(l, ",")[end] for l in readlines(d_path)] == ["IN"]
        finally
            rm(d_path; force = true)
        end
        @test_throws ArgumentError _extract_d_lines(zip_path; month_filter_column = "NO_SUCH_COLUMN", lo, hi)
    finally
        rm(csv_path; force = true)
        rm(zip_path; force = true)
    end
end

# A stand-in for HTTP.get that runs scripted (status, body) answers, writing each body to the response stream.
function scripted_http_get(script)
    calls = Ref(0)
    function http_get(url; response_stream = nothing, kwargs...)
        calls[] += 1
        status, body = script[min(calls[], length(script))]
        isnothing(response_stream) || write(response_stream, body)
        return HTTP.Response(status, isnothing(response_stream) ? body : "")
    end
    return http_get, calls
end

@testset "_download_and_cache: streams the body to the file, never into the response" begin
    http_get, calls = scripted_http_get([(200, "zip-bytes")])
    dest = joinpath(mktempdir(), "sub", "a.zip")
    @test _download_and_cache("http://example.invalid/a.zip", dest; http_get) === nothing
    @test read(dest, String) == "zip-bytes"
    @test calls[] == 1
end

@testset "_download_and_cache: a retry truncates the partial file from the failed attempt" begin
    http_get, calls = scripted_http_get([(503, "junk-from-the-failed-attempt"), (200, "ok")])
    dest = joinpath(mktempdir(), "a.zip")
    logs, _ = Test.collect_test_logs() do
        _download_and_cache("http://example.invalid/a.zip", dest; http_get)
    end
    @test calls[] == 2
    @test read(dest, String) == "ok"
end

@testset "_download_and_cache: a 404 throws MissingDataError and leaves no file" begin
    http_get, _ = scripted_http_get([(404, "not found page")])
    dest = joinpath(mktempdir(), "a.zip")
    @test_throws MissingDataError _download_and_cache("http://example.invalid/a.zip", dest; http_get)
    @test !isfile(dest)
end

@testset "_fetch_with_retry: without dest the body stays in the response" begin
    http_get, _ = scripted_http_get([(200, "body")])
    @test String(_fetch_with_retry("http://example.invalid/x"; http_get).body) == "body"
end

@testset "_csv_to_parquet: reads data rows, casts types, drops extra and absent columns" begin
    csv_path = make_nemweb_csv(
        "DISPATCHPRICE",
        ["SETTLEMENTDATE", "REGIONID", "RRP", "EXTRA_COL"],
        [
            ("2024/01/15 05:00:00", "NSW1", "100.5", "ignored"),
            ("2024/01/15 05:05:00", "VIC1", "98.3", "ignored"),
            ("2024/01/15 05:10:00", "QLD1", "102.1", "ignored"),
        ],
    )
    tmpdir = mktempdir()
    try
        _run_csv_to_parquet(csv_path, ["SETTLEMENTDATE", "REGIONID", "RRP", "ABSENT_COL"], tmpdir; year = 2024, month = 3)
        @test isdir(joinpath(tmpdir, "archive_month=2024-03-01"))
        df = sort(_read_parquet_file(tmpdir), :REGIONID)
        @test nrow(df) == 3  # C header and trailer are excluded
        @test df.REGIONID == ["NSW1", "QLD1", "VIC1"]
        @test !("EXTRA_COL" in names(df))
        @test all(ismissing, df.ABSENT_COL)
        row = df[df.REGIONID .== "NSW1", :]
        @test row.SETTLEMENTDATE[1] == DateTime(2024, 1, 15, 5, 0, 0)
        @test row.RRP[1] ≈ 100.5
    finally
        isfile(csv_path) && rm(csv_path)
    end
end

@testset "_csv_to_parquet: a column empty on every row becomes typed NULL, not a crash" begin
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
        @test eltype(df.RRP) <: Union{Missing, Float64}
    finally
        isfile(csv_path) && rm(csv_path)
    end
end

@testset "_csv_to_parquet: islocal=false does not call mkpath" begin
    # DuckDB's COPY creates at most one missing directory level, so a path two levels deep fails without mkpath.
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

@testset "month window: lines outside the archive month never reach the parquet, boundary interval included" begin
    csv_path = make_nemweb_csv("DISPATCH_FCAS_REQ_CONSTRAINT", ["INTERVAL_DATETIME", "REGIONID"], MONTH_FILTER_ROWS)
    zip_path = make_zip_with_csv(csv_path)
    lo, hi = _month_filter_bounds(2026, 6)
    tmpdir = mktempdir()
    try
        d_path, available_cols = _extract_d_lines(zip_path; month_filter_column = "INTERVAL_DATETIME", lo, hi)
        try
            # Out-of-month lines never reach the extracted file.
            @test Set(split(l, ",")[end] for l in readlines(d_path)) == Set(["FIRST", "LAST", "NEXT_BOUNDARY"])
            conn = DuckDB.DB()
            try
                _csv_to_parquet(
                    conn, d_path, available_cols, ["INTERVAL_DATETIME", "REGIONID"], tmpdir,
                    [ARCHIVE_MONTH_PARTITION], String[], 2026, 6;
                    month_filter_column = "INTERVAL_DATETIME",
                )
            finally
                DBInterface.close!(conn)
            end
        finally
            rm(d_path; force = true)
        end
        @test Set(_read_parquet_file(tmpdir).REGIONID) == Set(["FIRST", "LAST", "NEXT_BOUNDARY"])
    finally
        rm(csv_path; force = true)
        rm(zip_path; force = true)
    end
end

@testset "_csv_to_parquet: no month_filter_column: out-of-month rows are kept (other tables untouched)" begin
    csv_path = make_nemweb_csv(
        "DISPATCHPRICE",
        ["SETTLEMENTDATE", "REGIONID"],
        [("2026/05/31 23:55:00", "PREV"), ("2026/06/15 00:05:00", "IN_MONTH"), ("2026/07/01 00:05:00", "NEXT")],
    )
    tmpdir = mktempdir()
    try
        _run_csv_to_parquet(csv_path, ["SETTLEMENTDATE", "REGIONID"], tmpdir; year = 2026, month = 6)
        df = _read_parquet_file(tmpdir)
        @test nrow(df) == 3
    finally
        isfile(csv_path) && rm(csv_path)
    end
end

@testset "_csv_to_parquet: month_filter_column set: duplicate rows across parts are deduplicated on sort_by" begin
    csv_path = make_nemweb_csv(
        "DISPATCH_FCAS_REQ_CONSTRAINT",
        ["INTERVAL_DATETIME", "REGIONID", "RRP"],
        [
            ("2026/06/01 00:05:00", "NSW1", "10.0"),
            ("2026/06/01 00:05:00", "NSW1", "10.0"),  # duplicate key, as a second archive part would carry
            ("2026/06/01 00:05:00", "VIC1", "20.0"),
        ],
    )
    tmpdir = mktempdir()
    try
        _run_csv_to_parquet(
            csv_path, ["INTERVAL_DATETIME", "REGIONID", "RRP"], tmpdir;
            sort_by = ["INTERVAL_DATETIME", "REGIONID"],
            year = 2026, month = 6, month_filter_column = "INTERVAL_DATETIME",
        )
        df = _read_parquet_file(tmpdir)
        @test nrow(df) == 2
        @test Set(df.REGIONID) == Set(["NSW1", "VIC1"])
    finally
        isfile(csv_path) && rm(csv_path)
    end
end

@testset "DataSource: partitions, path and filesystem, local or remote" begin
    tmpdir = mktempdir()
    config = HiveConfiguration(hive_location = tmpdir)
    source = DataSource("T", ["C"], config)
    @test source.partitions == [ARCHIVE_MONTH_PARTITION]
    @test !isdir(source.path)  # construction is pure, the write path creates it lazily
    @test source.month_filter_column === nothing && source.row_filter === nothing
    for (location, filesystem, path) in ((tmpdir, "file", joinpath(tmpdir, "T")), ("bucket/path", "s3", "s3://bucket/path/T"))
        remote = DataSource("T", ["C"], HiveConfiguration(; hive_location = location, filesystem))
        @test remote.path == path
        @test AustralianElectricityMarketsData.get_filesystem(remote) == filesystem
        @test AustralianElectricityMarketsData.islocal(remote) == (filesystem == "file")
    end
end

@testset "MNSP and fast-start table specs: every non-key text column is typed explicitly" begin
    text_columns = Set(["PARTICIPANTID", "LINKID", "ENTRYTYPE", "INTERCONNECTORID", "DUID"])
    for name in ("MNSP_DAYOFFER", "MNSP_BIDOFFERPERIOD", "DISPATCH_MNSPBIDTRK")
        spec = only(filter(s -> s.name == name, _TABLE_SPECS))
        for col in spec.columns
            col in text_columns && continue
            @test haskey(AustralianElectricityMarketsData.COLUMN_TYPES, col)
        end
        @test issubset(spec.sort_by, spec.columns)
    end
    for (table, cols) in (
            "DISPATCHINTERCONNECTORRES" => ["FCASEXPORTLIMIT", "FCASIMPORTLIMIT"],
            "DISPATCHLOAD" => ["DISPATCHMODETIME"],
        )
        spec = only(filter(s -> s.name == table, _TABLE_SPECS))
        @test issubset(cols, spec.columns)
        @test all(c -> AustralianElectricityMarketsData.COLUMN_TYPES[c] != String, cols)
    end
end

@testset "_csv_to_parquet: timestamps with a millisecond fraction parse like plain ones" begin
    csv_path = make_nemweb_csv(
        "MNSP_DAYOFFER",
        ["SETTLEMENTDATE", "OFFERDATE", "LINKID"],
        [("2026/06/01 00:00:00", "2026/05/05 15:06:01.000", "BLNKVIC"), ("2026/06/01 00:00:00", "2026/05/31 08:53:38", "BLNKTAS")],
    )
    tmpdir = mktempdir()
    try
        _run_csv_to_parquet(csv_path, ["SETTLEMENTDATE", "OFFERDATE", "LINKID"], tmpdir)
        df = sort(_read_parquet_file(tmpdir), :LINKID)
        @test df.OFFERDATE == [DateTime(2026, 5, 31, 8, 53, 38), DateTime(2026, 5, 5, 15, 6, 1)]
    finally
        isfile(csv_path) && rm(csv_path)
    end
end

@testset "_csv_to_parquet: row_filter keeps only the matching rows" begin
    csv_path = make_nemweb_csv(
        "BIDDAYOFFER",
        ["DUID", "BIDTYPE", "SETTLEMENTDATE", "OFFERDATE", "T1"],
        [
            ("U1", "ENERGY", "2026/06/01 00:00:00", "2026/06/01 10:00:00.000", "5"),
            ("U1", "RAISE6SEC", "2026/06/01 00:00:00", "2026/06/01 10:00:00.000", ""),
            ("U1", "ENERGY", "2026/06/01 00:00:00", "2026/06/01 16:04:00.000", "0"),
        ],
    )
    tmpdir = mktempdir()
    try
        cols = ["DUID", "BIDTYPE", "SETTLEMENTDATE", "OFFERDATE", "T1"]
        _run_csv_to_parquet(csv_path, cols, tmpdir; row_filter = "BIDTYPE" => "ENERGY")
        df = sort(_read_parquet_file(tmpdir), :OFFERDATE)
        @test df.BIDTYPE == ["ENERGY", "ENERGY"]
        @test df.OFFERDATE == [DateTime(2026, 6, 1, 10), DateTime(2026, 6, 1, 16, 4)]
        @test df.T1 == [5.0, 0.0]
        @test_throws ArgumentError _run_csv_to_parquet(csv_path, cols, mktempdir(); row_filter = "ABSENT" => "X")
    finally
        isfile(csv_path) && rm(csv_path)
    end
end

@testset "BIDDAYOFFER spec: every rebid version, ENERGY rows only, typed fast-start columns" begin
    db = aem_connect(HiveConfiguration(hive_location = mktempdir()))
    source = get_table(db, :BIDDAYOFFER)
    @test source.row_filter == ("BIDTYPE" => "ENERGY")
    @test issubset(["OFFERDATE", "MINIMUMLOAD", "T1", "T2", "T3", "T4"], source.table_columns)
    @test issubset(source.table_sort_by, source.table_columns)
    @test AustralianElectricityMarketsData.COLUMN_TYPES["OFFERDATE"] == DateTime
    @test get_table(db, :BIDDAYOFFER_D).row_filter === nothing
end

@testset "get_table: month_filter_column is set only for DISPATCH_FCAS_REQ_CONSTRAINT" begin
    tmpdir = mktempdir()
    db = aem_connect(HiveConfiguration(hive_location = tmpdir))
    @test get_table(db, :DISPATCH_FCAS_REQ_CONSTRAINT).month_filter_column == "INTERVAL_DATETIME"
    for name in ("DISPATCHPRICE", "DISPATCHLOAD", "DISPATCH_FCAS_REQ")
        @test get_table(db, Symbol(name)).month_filter_column === nothing
    end
end

@testset "get_table: throws ArgumentError with table name in message for unknown symbol" begin
    tmpdir = mktempdir()
    db = aem_connect(HiveConfiguration(hive_location = tmpdir))
    err = (@test_throws ArgumentError get_table(db, :NONEXISTENT_TABLE)).value
    @test occursin("NONEXISTENT_TABLE", err.msg)
end

@testset "populate: skips download when Hive partition already exists" begin
    tmpdir = mktempdir()
    source = DataSource("DISPATCHPRICE", ["SETTLEMENTDATE", "REGIONID", "RRP"], HiveConfiguration(hive_location = tmpdir))

    partition_dir = joinpath(source.path, "archive_month=2024-01-01")
    mkpath(partition_dir)
    stub = joinpath(partition_dir, "data.parquet")
    write(stub, UInt8[])  # zero-byte stub stands in for real parquet

    date_range = Date(2024, 1, 1):Month(1):Date(2024, 1, 1)
    @test_logs (:info, r"already exists") min_level = Logging.Info match_mode = :any populate(source, date_range)
    @test isfile(stub)  # stub untouched, no download occurred
end

@testset "_clear_local_partition removes a local source's partition and leaves a remote one's" begin
    # Only the source's scheme decides; the gs:// path is unrelated to `partition_dir`.
    for filesystem in ("file", "gs")
        tmpdir = mktempdir()
        source = DataSource("T", ["C"], HiveConfiguration(; hive_location = filesystem == "file" ? tmpdir : "bucket/path", filesystem))
        partition_dir = joinpath(tmpdir, "archive_month=2024-01-01")
        mkpath(partition_dir)
        write(joinpath(partition_dir, "data.parquet"), UInt8[1, 2, 3])
        AustralianElectricityMarketsData._clear_local_partition(source, partition_dir)
        @test isdir(partition_dir) == (filesystem == "gs")
    end
end

@testset "_add_data: a failed fetch leaves the month's existing partition intact" begin
    tmpdir = mktempdir()
    source = DataSource("DISPATCHPRICE", ["SETTLEMENTDATE", "REGIONID", "RRP"], HiveConfiguration(hive_location = tmpdir))
    partition_dir = joinpath(source.path, "archive_month=2024-01-01")
    mkpath(partition_dir)
    stub = joinpath(partition_dir, "data.parquet")
    write(stub, UInt8[1, 2, 3])

    transient_fetch(table, year, month) = throw(TransientDownloadError("rate limited"))
    @test_throws TransientDownloadError AustralianElectricityMarketsData._add_data(source, 2024, 1; fetch_archive = transient_fetch)
    @test isfile(stub)

    unpublished_fetch(table, year, month) = throw(MissingDataError("HTTP 404"))
    @test_logs (:error, r"not published") match_mode = :any AustralianElectricityMarketsData._add_data(
        source, 2024, 1; fetch_archive = unpublished_fetch,
    )
    @test isfile(stub)
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

using AustralianElectricityMarketsData: _RemoteBytes, _get_legacy_archive, populate_legacy_archive,
    LEGACY_ARCHIVE_FIRST_MONTH, AEMDB, aem_connect

# A monthly archive: outer ZIP whose entries mimic MMSDM_<yyyy>_<mm>.zip, each table's own ZIP nested inside.
function make_monthly_archive(year, month, tables)
    mm = lpad(month, 2, '0')
    inner = Dict(
        t => make_zip_with_csv(make_nemweb_csv(t, ["GENCONID", "EFFECTIVEDATE"], [["X$t", "$year/$mm/04 00:00:00"]]))
            for t in tables
    )
    outer = IOBuffer()
    w = ZipFile.Writer(outer)
    f = ZipFile.addfile(w, "$mm/MMSDM_Historical_Data_SQLLoader/CTL/readme.txt")
    write(f, "ignored\n")
    for t in tables
        f = ZipFile.addfile(w, "$mm/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_DVD_$(t)_$year$(mm)010000.zip")
        write(f, read(inner[t]))
    end
    close(w)
    return take!(outer)
end

@testset "_RemoteBytes: indexes like the underlying bytes and fetches each block once" begin
    data = rand(UInt8, 3 * AustralianElectricityMarketsData._REMOTE_BLOCK_BYTES + 17)
    requests = Tuple{Int, Int}[]
    remote = _RemoteBytes(length(data)) do lo, hi
        push!(requests, (lo, hi))
        return data[(lo + 1):(hi + 1)]
    end
    @test length(remote) == length(data)
    @test remote[1] == data[1] && remote[end] == data[end]
    @test collect(remote[(end - 5):end]) == data[(end - 5):end]
    @test length(requests) == 2                       # first and last block only
    @test remote[2] == data[2] && length(requests) == 2
end

@testset "_get_legacy_archive: extracts only the requested table's nested ZIP" begin
    archive = make_monthly_archive(2013, 8, ["GENCONDATA", "SPDREGIONCONSTRAINT"])
    paths = _get_legacy_archive("GENCONDATA", 2013, 8; open_archive = (y, m) -> archive)
    try
        @test length(paths) == 1
        lines = readlines(IOBuffer(first(_extract_d_lines(paths)) |> read))
        @test any(startswith("D,TEST,GENCONDATA"), lines)
        @test !any(contains("SPDREGIONCONSTRAINT"), lines)
    finally
        foreach(rm, paths)
    end
end

@testset "_get_legacy_archive: a table absent from the archive is a MissingDataError" begin
    archive = make_monthly_archive(2013, 8, ["GENCONDATA"])
    @test_throws MissingDataError _get_legacy_archive("SPDREGIONCONSTRAINT", 2013, 8; open_archive = (y, m) -> archive)
end

@testset "populate with a custom fetch_archive writes the Hive partition" begin
    tmpdir = mktempdir()
    source = DataSource(
        "GENCONDATA", ["GENCONID", "EFFECTIVEDATE"], HiveConfiguration(hive_location = tmpdir),
    )
    archive = make_monthly_archive(2013, 8, ["GENCONDATA"])
    fetch_archive(t, y, m) = _get_legacy_archive(t, y, m; open_archive = (yy, mm) -> archive)
    populate(source, Date(2013, 8, 1):Month(1):Date(2013, 8, 1); fetch_archive)
    df = _read_parquet_file(joinpath(source.path, "archive_month=2013-08-01", "*.parquet"))
    @test df.GENCONID == ["XGENCONDATA"]
end

@testset "populate_legacy_archive: rejects months outside the monolithic-archive window" begin
    db = aem_connect(HiveConfiguration(hive_location = mktempdir()))
    @test_throws ArgumentError populate_legacy_archive(db, :GENCONDATA, Date(2015, 1, 1), Date(2015, 1, 1))
    @test_throws ArgumentError populate_legacy_archive(db, :GENCONDATA, Date(2009, 6, 1), Date(2009, 6, 1))
end
