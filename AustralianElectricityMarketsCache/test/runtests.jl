using AustralianElectricityMarketsCache
using Aqua
using Test
using Dates
using DataFrames
using DBInterface

const Cache = AustralianElectricityMarketsCache

@testset "Cache infrastructure" begin
    root = mktempdir()
    db = aem_connect(HiveConfiguration(hive_location = root))
    source = get_table(db, :DISPATCHPRICE)
    @test source.path == joinpath(root, "DISPATCHPRICE")
    @test Cache._parse_hive_root(HiveConfiguration(hive_location = "bucket/prefix", filesystem = "s3")) == "s3://bucket/prefix"
    @test Cache._parse_hive_root(HiveConfiguration(hive_location = "bucket/prefix", filesystem = "gs")) == "gs://bucket/prefix"
end

# Parquet stubs under `root/<table>/archive_month=<month>/`; an empty month directory holds none.
function make_partitions(root, table, months; empty_months = String[])
    for month in months
        dir = joinpath(root, table, "archive_month=$month")
        mkpath(dir)
        write(joinpath(dir, "part-0.parquet"), UInt8[])
    end
    for month in empty_months
        mkpath(joinpath(root, table, "archive_month=$month"))
    end
    return
end

@testset "partitions: local listing and date range" begin
    root = mktempdir()
    db = aem_connect(HiveConfiguration(hive_location = root))
    source = get_table(db, :DISPATCHPRICE)
    @test Cache._cached_months(source) == Date[]
    @test Cache.cached_date_range(source) === nothing

    make_partitions(
        root, "DISPATCHPRICE", ["2024-01-01", "2024-03-01"]; empty_months = ["2024-05-01"]
    )
    mkpath(joinpath(root, "DISPATCHPRICE", "not_a_partition"))
    @test Cache._cached_months(source) == [Date(2024, 1, 1), Date(2024, 3, 1)]
    @test Cache.cached_date_range(source) == (Date(2024, 1, 1), Date(2024, 3, 31))
    @test Cache._partition_has_data(source, joinpath(source.path, "archive_month=2024-03-01"))
    @test !Cache._partition_has_data(source, joinpath(source.path, "archive_month=2024-05-01"))
end

@testset "partitions: one glob query lists months, parsed from the paths" begin
    root = mktempdir()
    make_partitions(root, "T", ["2023-12-01", "2024-02-01"]; empty_months = ["2024-03-01"])
    write(joinpath(root, "T", "archive_month=2024-02-01", "part-1.parquet"), UInt8[])
    write(joinpath(root, "T", "archive_month=2024-02-01", "notes.txt"), UInt8[])

    conn = Cache._new_duckdb_connection()
    try
        files = Cache._glob_partition_files(conn, joinpath(root, "T"))
        @test length(files) == 3  # two parquet files in February, one in December, no .txt
        @test Cache._months_from_paths(files) == [Date(2023, 12, 1), Date(2024, 2, 1)]
    finally
        DBInterface.close!(conn)
    end

    s3_files = [
        "s3://bucket/T/archive_month=2024-02-01/a.parquet",
        "s3://bucket/T/archive_month=2024-02-01/b.parquet",
        "s3://bucket/T/archive_month=2024-04-01/a.parquet",
        "s3://bucket/T/archive_month=2024-04-01/readme.txt",
    ]
    @test Cache._months_from_paths(s3_files) == [Date(2024, 2, 1), Date(2024, 4, 1)]
end

@testset "partitions: a supplied connection is reused, not closed" begin
    root = mktempdir()
    make_partitions(root, "T", ["2024-01-01"])
    conn = Cache._new_duckdb_connection()
    try
        @test Cache._with_connection(c -> c === conn, conn, get_table(aem_connect(HiveConfiguration(hive_location = root)), :DISPATCHPRICE))
        # Still open: a query on it succeeds.
        @test DataFrame(DBInterface.execute(conn, "SELECT 1 AS x")).x == [1]
    finally
        DBInterface.close!(conn)
    end
end

@testset "Aqua" begin
    Aqua.test_all(Cache; ambiguities = false, persistent_tasks = false)
end
