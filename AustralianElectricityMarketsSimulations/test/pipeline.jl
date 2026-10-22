@testset "simulation consumes an existing system without a database" begin
    apis = (:prepare_replication!, :replication_simulation, :replication_results)
    for api in apis
        @test isdefined(AEMS, api)
    end
    if all(api -> isdefined(AEMS, api), apis)
        t = DateTime(2025, 1, 1, 0, 5)
        steps = t:Minute(5):(t + Minute(5))
        for in_memory in (true, false)
            db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR))
            sys = nem_system(
                db, ReplayNetworkConfiguration(); date_range = t:Minute(5):(t + Minute(15)),
                time_series_in_memory = in_memory, time_series_directory = mktempdir()
            )
            DuckDB.close(db.db)
            @test_throws r"prepare_replication!" replication_simulation(sys, steps)
            @test prepare_replication!(sys) === sys
            @test_throws r"already.*forecast" prepare_replication!(sys)
            @test_throws r"cover" replication_simulation(sys, (t + Hour(1)):Minute(5):(t + Hour(1)))
            @test_throws ArgumentError replication_simulation(sys, t:Minute(10):(t + Minute(10)))
            @test_throws ArgumentError replication_simulation(sys, t:Minute(5):(t - Minute(5)))
            skipped = NamedTuple[]
            folder = mktempdir()
            simulation = replication_simulation(sys, steps; name = "custom_dispatch", simulation_name = "custom_run", skipped, folder)
            @test simulation isa PSI.Simulation
            @test isnothing(simulation.internal)
            @test PSI.get_steps(simulation) == 2
            @test PSI.build!(simulation; store_systems_in_results = false) == PSI.SimulationBuildStatus.BUILT
            @test PSI.execute!(simulation) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
            results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "custom_dispatch")
            reopened = PSI.get_decision_problem_results(PSI.SimulationResults(folder, "custom_run"), "custom_dispatch")
            @test PSI.read_optimizer_stats(reopened).objective_value == PSI.read_optimizer_stats(results).objective_value
            out = replication_results(results, sys)
            # The mock includes SNOWY1 alongside the five current regions.
            @test nrow(out.solved.prices) == 12
            @test Set(out.solved.prices.SETTLEMENTDATE) == Set(steps)
            @test all(isfinite, out.solved.prices.ROP)
            @test any(!ismissing, out.solved.dispatch.TOTALCLEARED)
            @test names(out.ramp_violations) == ["DUID", "DateTime", "MW", "direction"]
            @test all(in(steps), out.constraint_violations.DateTime)
            @test all(in((:no_available_device, :never_invoked)), getproperty.(skipped, :reason))
        end
    end
end
