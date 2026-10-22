using AustralianElectricityMarketsCache
using Aqua
using Dates
using DuckDB
using Test

const Cache = AustralianElectricityMarketsCache

@testset "Cache infrastructure" begin
    root = mktempdir()
    db = aem_connect(HiveConfiguration(hive_location = root))
    source = get_table(db, :DISPATCHPRICE)
    @test source.path == joinpath(root, "DISPATCHPRICE")
    @test Cache.cached_date_range(source) === nothing
    partition = joinpath(source.path, "archive_month=2025-01-01")
    mkpath(partition)
    DuckDB.execute(db.db, "COPY (SELECT 1 AS value) TO '$(joinpath(partition, "data.parquet"))' (FORMAT PARQUET)")
    @test Cache.cached_date_range(source) == (Date(2025, 1, 1), Date(2025, 1, 31))
    @test occursin("DISPATCHPRICE", sprint(show, MIME"text/plain"(), db))
    @test occursin(root, sprint(show, db))
    @test Cache._parse_hive_root(HiveConfiguration(hive_location = "bucket/prefix", filesystem = "s3")) == "s3://bucket/prefix"
    @test Cache._parse_hive_root(HiveConfiguration(hive_location = "bucket/prefix", filesystem = "gs")) == "gs://bucket/prefix"
end

@testset "Aqua" begin
    Aqua.test_all(Cache; ambiguities = false, persistent_tasks = false)
end
