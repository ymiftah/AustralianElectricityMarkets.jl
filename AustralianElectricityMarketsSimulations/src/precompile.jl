using PrecompileTools: @compile_workload

# The mock NEMWEB cache shared with the test suites, with DuckDB reached through
# AustralianElectricityMarkets because this package does not depend on it directly.
module _PrecompileMockData
    import AustralianElectricityMarkets
    const DuckDB = AustralianElectricityMarkets.DuckDB
    function _drop_duckdb_using(ex)
        return ex == :(using DuckDB) ? nothing : ex
    end
    include(_drop_duckdb_using, joinpath(@__DIR__, "..", "..", "test", "fixtures", "mock_data.jl"))
end

function _precompile_workload()
    hive = mktempdir()
    _PrecompileMockData.create_mock_data(hive; complete_inputs = true)
    _PrecompileMockData.write_mock_interconnector_results(hive)
    start = DateTime(2025, 1, 1, 0, 5)
    steps = start:DISPATCH_INTERVAL:(start + DISPATCH_INTERVAL)
    db = AustralianElectricityMarkets.aem_connect(AustralianElectricityMarkets.HiveConfiguration(hive_location = hive))
    sys = try
        AustralianElectricityMarkets.nem_system(
            db, AustralianElectricityMarkets.NEMDEConfiguration();
            date_range = start:DISPATCH_INTERVAL:(start + 3 * DISPATCH_INTERVAL),
        )
    finally
        _PrecompileMockData.DuckDB.close(db.db)
    end
    prepare_replication!(sys)
    run = run_replication(sys, steps; folder = mktempdir())
    replication_results(run.results, sys)
    return
end

# Build, step and read back a two-interval replay while creating the package cache.
@compile_workload begin
    Base.CoreLogging.with_logger(_precompile_workload, Base.CoreLogging.NullLogger())
end
