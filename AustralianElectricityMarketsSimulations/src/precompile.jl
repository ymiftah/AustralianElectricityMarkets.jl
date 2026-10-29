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

# Builds, executes and reads back a two-interval replay through the public API, mirroring the template
# inputs of the replay runner (`scripts/replay_simulation.jl`).
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
    AustralianElectricityMarkets.prepare_replay_forecasts!(sys)
    check_replication_steps(sys, steps)
    check_single_financial_year(steps)
    check_tie_break_pairs(sys, steps)
    template = replication_template(
        sys; initial_time = first(steps), exclude_constraints = never_invoked_constraints(sys, steps),
    )
    check_fcas_services(sys, template)
    check_dispatch_envelope(sys, template, first(steps), length(steps))
    # Must match REPLICATION_HIGHS_OPTIONS in scripts/replay_simulation.jl.
    optimizer = JuMP.optimizer_with_attributes(
        HiGHS.Optimizer, "mip_rel_gap" => 1.0e-8, "mip_abs_gap" => 1.0e-10,
        "mip_heuristic_run_rins" => false, "mip_heuristic_run_rens" => false,
        "mip_heuristic_run_root_reduced_cost" => false, "mip_heuristic_run_feasibility_jump" => false,
    )
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
    results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch")
    # Realized reads of the dispatch variable and the area balance dual, as the replay results do.
    variable_names = [
        PSI.IS.Optimization.encode_key_as_string(k) for k in PSI.list_variable_keys(results)
            if PSI.IS.Optimization.get_entry_type(k) === PSI.ActivePowerVariable
    ]
    PSI.read_realized_variables(results, variable_names)
    PSI.read_realized_duals(results, [PSI.ConstraintKey(PSI.CopperPlateBalanceConstraint, PSY.Area)])
    return
end

# Build, step and read back a two-interval replay while creating the package cache.
@compile_workload begin
    Base.CoreLogging.with_logger(_precompile_workload, Base.CoreLogging.NullLogger())
end
