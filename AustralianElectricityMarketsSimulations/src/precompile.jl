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

# Builds and executes a two-interval replication through the public API, as the replay runner does.
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
    AustralianElectricityMarkets.prepare_replay_forecasts!(sys)
    check_replication_steps(sys, steps)
    check_single_financial_year(steps)
    template = replication_template(sys)
    check_fcas_services(sys, template)
    check_dispatch_envelope(sys, template, first(steps), length(steps))
    optimizer = JuMP.optimizer_with_attributes(HiGHS.Optimizer, "mip_rel_gap" => 0.0, "mip_abs_gap" => 1.0e-10)
    model = replication_decision_model(template, sys, first(steps); optimizer = optimizer, name = "dispatch")
    models = PSI.SimulationModels(; decision_models = [model])
    sequence = PSI.SimulationSequence(; models = models, ini_cond_chronology = PSI.InterProblemChronology())
    simulation = PSI.Simulation(;
        name = "replication", steps = length(steps), models = models,
        sequence = sequence, simulation_folder = mktempdir(), initial_time = first(steps),
    )
    PSI.build!(simulation; store_systems_in_results = false) == PSI.SimulationBuildStatus.BUILT ||
        error("precompile replication failed to build")
    PSI.execute!(simulation) == PSI.RunStatus.SUCCESSFULLY_FINALIZED ||
        error("precompile replication failed to execute")
    PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch")
    return
end

# Build, step and read back a two-interval replay while creating the package cache.
@compile_workload begin
    Base.CoreLogging.with_logger(_precompile_workload, Base.CoreLogging.NullLogger())
end
