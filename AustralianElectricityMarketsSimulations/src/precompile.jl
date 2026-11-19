using PrecompileTools: @compile_workload

# The mock NEMWEB cache shared with the test suites, with DuckDB reached through
# AustralianElectricityMarkets because this package does not depend on it directly. The fixture
# lives in the repository, not in the installed subdirectory package, so the workload is skipped without it.
module _PrecompileMockData
    import AustralianElectricityMarkets
    const DuckDB = AustralianElectricityMarkets.DuckDB
    const FIXTURE = joinpath(@__DIR__, "..", "..", "test", "fixtures", "mock_data.jl")
    const AVAILABLE = isfile(FIXTURE)
    function _drop_duckdb_using(ex)
        return ex == :(using DuckDB) ? nothing : ex
    end
    if AVAILABLE
        # Tracked so that editing the fixture recompiles this package.
        Base.include_dependency(FIXTURE)
        include(_drop_duckdb_using, FIXTURE)
    end
end

# Builds a single-decision-model simulation of `problem` over `steps` of `sys`, returning it unbuilt.
function _precompile_build(problem, template, sys, steps)
    model = PSI.DecisionModel(problem, template, sys; optimizer = nemde_optimizer(), initial_time = first(steps), name = "dispatch")
    models = PSI.SimulationModels(; decision_models = [model])
    sequence = PSI.SimulationSequence(; models = models, ini_cond_chronology = PSI.InterProblemChronology())
    simulation = PSI.Simulation(;
        name = "NEMDE", steps = length(steps), models = models,
        sequence = sequence, simulation_folder = mktempdir(), initial_time = first(steps),
    )
    PSI.build!(simulation; store_systems_in_results = false) == PSI.SimulationBuildStatus.BUILT ||
        error("precompile NEMDE failed to build")
    return simulation
end

# Builds the models of a two-interval run from the mock NEMWEB cache, with the inputs and steps of
# the run workflow (`nem_system` followed by a PSI simulation). Execution and result reads are
# not cached: they compile on first use in a session.
function _precompile_workload()
    _PrecompileMockData.AVAILABLE || return
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
    template = template_nemde()
    _precompile_build(NEMDispatchProblem, template, sys, steps)
    # The closed-loop path (state update, per-step inputs) builds on its own two-step run.
    _precompile_build(NEMClosedLoopDispatchProblem, template, sys, steps)
    return
end

# Builds the two-interval run's models while creating the package cache; execution is not cached.
@compile_workload begin
    Base.CoreLogging.with_logger(_precompile_workload, Base.CoreLogging.NullLogger())
end
