using AustralianElectricityMarketsData
using TOML
using Logging

@testset "Independent population and reader packages" begin
    @test isdefined(AustralianElectricityMarkets, :Readers)
    if isdefined(AustralianElectricityMarkets, :Readers)
        readers = AustralianElectricityMarkets.Readers
        @test read_units === readers.read_units
        @test read_demand === readers.read_demand
        @test read_fcas_bids === readers.read_fcas_bids
        @test parentmodule(read_units) === readers
        @test parentmodule(read_fcas_bids) === readers
    end

    @test HiveConfiguration === AustralianElectricityMarketsData.HiveConfiguration
    @test aem_connect === AustralianElectricityMarketsData.aem_connect
    @test !isdefined(AustralianElectricityMarkets, :populate)
    @test !isdefined(AustralianElectricityMarketsData, :read_demand)
    @test !isdefined(AustralianElectricityMarketsData, :read_units)

    root = dirname(@__DIR__)
    aem_deps = TOML.parsefile(joinpath(root, "Project.toml"))["deps"]
    data_deps = TOML.parsefile(joinpath(root, "AustralianElectricityMarketsData", "Project.toml"))["deps"]
    sim_deps = TOML.parsefile(joinpath(root, "AustralianElectricityMarketsSimulations", "Project.toml"))["deps"]
    @test !haskey(aem_deps, "AustralianElectricityMarketsData")
    @test !haskey(aem_deps, "AustralianElectricityMarketsSimulations")
    @test !haskey(aem_deps, "PowerSimulations")
    @test !haskey(sim_deps, "DuckDB")
    @test !haskey(data_deps, "AustralianElectricityMarkets")
    @test !haskey(data_deps, "AustralianElectricityMarketsSimulations")
    @test !haskey(sim_deps, "AustralianElectricityMarketsData")
    @test haskey(sim_deps, "AustralianElectricityMarkets")

    cache_dir = mktempdir()
    partition = joinpath(cache_dir, "DISPATCHPRICE", "archive_month=2025-01-01")
    mkpath(partition)
    db = aem_connect(HiveConfiguration(hive_location = cache_dir))
    DuckDB.execute(
        db.db,
        "COPY (SELECT TIMESTAMP '2025-01-01 00:05:00' AS SETTLEMENTDATE, 'NSW1' AS REGIONID, 42.0 AS RRP, 42.0 AS ROP, 0 AS INTERVENTION) TO '$(joinpath(partition, "data.parquet"))' (FORMAT PARQUET)",
    )
    @test_logs (:info, r"already exists") min_level = Logging.Info match_mode = :any AustralianElectricityMarketsData.populate(
        db, :DISPATCHPRICE, Date(2025, 1, 1), Date(2025, 1, 1),
    )
    prices = read_prices(db, DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 1, 0, 10))
    @test only(prices.RRP) == 42.0
end
