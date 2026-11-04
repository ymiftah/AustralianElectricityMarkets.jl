@testset "simulation consumes an existing system without a database" begin
    t = DateTime(2025, 1, 1, 0, 5)
    steps = t:Minute(5):(t + Minute(5))
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR))
    sys = nem_system(
        db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(15)),
        time_series_in_memory = false, time_series_directory = mktempdir()
    )
    DuckDB.close(db.db)
    @test PowerSystems.get_time_series_counts(sys).forecast_count == 0
    @test AEMS._prepare_replay_forecasts!(sys) === sys
    forecasts = PowerSystems.get_time_series_counts(sys).forecast_count
    @test AEMS._prepare_replay_forecasts!(sys) === sys
    @test PowerSystems.get_time_series_counts(sys).forecast_count == forecasts
    @test_throws r"cover" replay_simulation(sys, (t + Hour(1)):Minute(5):(t + Hour(1)))
    @test_throws ArgumentError replay_simulation(sys, t:Minute(10):(t + Minute(10)))
    @test_throws ArgumentError replay_simulation(sys, t:Minute(5):(t - Minute(5)))
    folder = mktempdir()
    replay = replay_simulation(sys, steps; name = "custom_dispatch", simulation_name = "custom_run", folder)
    simulation = replay.simulation
    skipped = replay.skipped_constraints
    @test simulation isa PSI.Simulation
    @test isnothing(simulation.internal)
    @test PSI.get_steps(simulation) == 2
    @test PSI.build!(simulation; store_systems_in_results = false) == PSI.SimulationBuildStatus.BUILT
    @test PSI.execute!(simulation) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "custom_dispatch")
    reopened = PSI.get_decision_problem_results(PSI.SimulationResults(folder, "custom_run"), "custom_dispatch")
    @test PSI.read_optimizer_stats(reopened).objective_value == PSI.read_optimizer_stats(results).objective_value
    solved = read_solved_interval(results, sys)
    violations = read_constraint_violations(results, sys)
    # The mock includes SNOWY1 alongside the five current regions.
    @test nrow(solved.prices) == 12
    @test Set(solved.prices.SETTLEMENTDATE) == Set(steps)
    @test all(isfinite, solved.prices.ROP)
    @test any(!ismissing, solved.dispatch.TOTALCLEARED)
    ramp = select(filter(:family => ==("unit_ramp"), violations), :name => :DUID, :DateTime, :MW, :direction)
    @test names(ramp) == ["DUID", "DateTime", "MW", "direction"]
    @test all(in(steps), violations.DateTime)
    @test all(in((:no_available_device, :never_invoked)), skipped.reason)
end
