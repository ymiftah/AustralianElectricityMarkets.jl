using AustralianElectricityMarketsData
using TOML
using Logging

@testset "Independent population and reader packages" begin
    AEM = AustralianElectricityMarkets
    @test !isdefined(AEM.Readers, :PowerSystems)
    @test all(name -> isdefined(AEM, name), (:EnergyTieBreak, :MARKET_PRICE_CAP_BY_FINANCIAL_YEAR, :constraint_cvp_factor))
    @test !any(name -> isdefined(AEM, name), (:set_fcas_effective_offers!, :get_fcas_offer, :populate))
    @test !any(name -> isdefined(AustralianElectricityMarketsData, name), (:read_demand, :read_units))
    @test HiveConfiguration === AustralianElectricityMarketsData.HiveConfiguration
    @test aem_connect === AustralianElectricityMarketsData.aem_connect

    # (package directory, dependency, whether it may depend on it); "" is the root package.
    root = dirname(@__DIR__)
    deps(package) = TOML.parsefile(joinpath(root, package, "Project.toml"))["deps"]
    allowed = [
        ("", "AustralianElectricityMarketsData", false), ("", "AustralianElectricityMarketsSimulations", false),
        ("", "PowerSimulations", false), ("AustralianElectricityMarketsData", "AustralianElectricityMarkets", false),
        ("AustralianElectricityMarketsData", "AustralianElectricityMarketsSimulations", false),
        ("AustralianElectricityMarketsSimulations", "DuckDB", false),
        ("AustralianElectricityMarketsSimulations", "AustralianElectricityMarketsData", false),
        ("AustralianElectricityMarketsSimulations", "AustralianElectricityMarkets", true),
    ]
    @test [haskey(deps(package), dep) for (package, dep, _) in allowed] == last.(allowed)

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

    @testset "the simulation package never reads the cache" begin
        offenders = String[]
        source = joinpath(root, "AustralianElectricityMarketsSimulations", "src")
        scanned = 0
        for (directory, _, files) in walkdir(source), file in files
            file == "precompile.jl" && continue
            scanned += 1
            path = joinpath(directory, file)
            for (number, line) in enumerate(eachline(path))
                occursin(r"\bAEMDB\b|\baem_connect\b|\bread_hive\b", line) || continue
                push!(offenders, "$path:$number: $(strip(line))")
            end
        end
        @test scanned > 0
        @test isempty(offenders) || error("AEMSim source reads the cache:\n" * join(offenders, "\n"))
    end
end
