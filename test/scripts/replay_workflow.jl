include(joinpath(@__DIR__, "..", "..", "scripts", "replay_workflow.jl"))
using .ReplayWorkflow: replicate_range

# Prepares a cache-built system for the script's result-reading regressions.
function workflow_test_system(db, date_range; kwargs...)
    return prepare_replication!(nem_system(db, NEMDEConfiguration(); date_range, kwargs...))
end

@testset "simulation runtime exposes no cache entry points" begin
    for api in (:replication_system, :replicate_range, :read_interval_inputs, :read_published_interval, :aem_connect)
        @test !isdefined(AEMS, api)
    end
end

@testset "Replication pipeline" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    t = DateTime(2025, 1, 1, 0, 5, 0)

    @testset "replicate_range replays one interval, solves and compares" begin
        result = replicate_range(db, t, t)
        @test only(result.results) isa PSI.SimulationProblemResults
        skipped = result.skipped_constraints
        @test names(skipped) == ["chunk", "constraint", "reason", "n_missing"]
        @test all(in((:no_available_device, :never_invoked)), skipped.reason)
        comparison = result.comparison
        published = read_published_interval(db, t)

        # One row per published key, so nothing is dropped silently.
        @test all(==(t), comparison.prices.SETTLEMENTDATE)
        @test nrow(comparison.prices) == nrow(published.prices)
        @test nrow(comparison.dispatch) == nrow(published.dispatch)
        @test nrow(comparison.interconnectors) == nrow(published.interconnectors)
        @test nrow(comparison.fcas_prices) == nrow(published.fcas_prices)
        @test all(==(t), comparison.fcas_prices.SETTLEMENTDATE)

        @test issubset(Set(["NSW1", "QLD1", "SA1", "TAS1", "VIC1"]), Set(comparison.prices.REGIONID))
        @test all(isfinite, skipmissing(comparison.prices.ROP_solved))
        @test any(!ismissing, comparison.prices.ROP_solved)
        @test any(!ismissing, comparison.dispatch.TOTALCLEARED_solved)
        @test any(!ismissing, comparison.interconnectors.MWFLOW_solved)
        @test all(isfinite, skipmissing(comparison.interconnectors.MWLOSSES_solved))
        @test any(!ismissing, comparison.fcas_prices.ROP_solved)
        # The scheduled load PUMP1 is solved, as a non-negative consumed MW.
        pump = only(filter(:DUID => ==("PUMP1"), comparison.dispatch))
        @test !ismissing(pump.TOTALCLEARED_solved)
        @test pump.TOTALCLEARED_solved >= 0
        # The 1-second markets are published, modelled and compared like the other FCAS markets.
        for bid_type in (BidType.RAISE1SEC, BidType.LOWER1SEC)
            rows = filter(:BIDTYPE => ==(bid_type), comparison.fcas_prices)
            @test !isempty(rows)
            @test any(!ismissing, rows.ROP_solved)
        end
        # The unavailable IC6 has no solved flow.
        @test ismissing(only(filter(:INTERCONNECTORID => ==("IC6"), comparison.interconnectors)).MWFLOW_solved)
    end

    @testset "MNSP offers reach the replay model" begin
        # The mock offers Basslink-like links on IC2 (300 MW available) for the intervals up to 04:00.
        sys = workflow_test_system(db, t:Minute(5):(t + Minute(10)))
        ic2 = get_component(AreaInterchange, sys, "IC2")
        @test has_time_series(ic2, SingleTimeSeries, "mnsp_forward_max_avail")
        result = replicate_range(db, t, t; interval_flow_limits = true)
        @test any(
            k -> PSI.IS.Optimization.get_entry_type(k) === MNSPLinkFlowVariable,
            PSI.list_variable_keys(only(result.results)),
        )
        flow = only(filter(:INTERCONNECTORID => ==("IC2"), result.comparison.interconnectors)).MWFLOW_solved
        @test abs(flow) <= 300.0 + 1.0e-6
    end
end


@testset "replicate_range on the mock cache" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 10)
    result = replicate_range(db, t1, t2)
    @test nrow(result.chunks) == 1 && length(result.results) == 1
    c = result.comparison
    for table in (:prices, :dispatch, :interconnectors)
        @test first(names(c[table])) == "SETTLEMENTDATE" && Set(c[table].SETTLEMENTDATE) == Set([t1, t2])
        @test nrow(c[table]) == sum(nrow(read_published_interval(db, t)[table]) for t in (t1, t2))
    end
    @test all(isfinite, skipmissing(c.prices.ROP_solved)) && any(!ismissing, c.prices.ROP_solved)
    @test any(!ismissing, c.dispatch.TOTALCLEARED_solved)
    # Interchanges are modeled (the unavailable IC6 is not), and so is FCAS.
    @test any(!ismissing, c.interconnectors.MWFLOW_solved)
    @test all(isfinite, skipmissing(c.interconnectors.MWLOSSES_solved))
    @test all(ismissing, filter(:INTERCONNECTORID => ==("IC6"), c.interconnectors).MWFLOW_solved)
    @test any(!ismissing, c.fcas_prices.ROP_solved) && all(isfinite, skipmissing(c.fcas_prices.ROP_solved))
    # Invoked at 00:10 only over BW01-BW04: modeled now that batteries are, and masked at 00:05.
    @test !any(startswith("N_PARTIAL_COVERAGE"), result.skipped_constraints.constraint)
    duals = stock_gc_duals(result.results[1])
    partial = only(k for k in keys(duals) if startswith(k, "N_PARTIAL_COVERAGE"))
    @test duals[partial][t1] == 0.0
    @test any(!ismissing, c.dispatch.TOTALCLEARED_solved[c.dispatch.DUID .== "BW01"])
    # The MNSP IC2 is modeled with its link offers in both steps.
    links = only(values(PSI.read_realized_variables(result.results[1], ["MNSPLinkFlowVariable__AreaInterchange"])))
    @test Set(links.DateTime) == Set([t1, t2]) && all(>=(-1.0e-9), links.value)
    @test names(result.ramp_violations) == ["DUID", "DateTime", "MW", "direction"]
    @test issubset(Set(result.constraint_violations.DateTime), Set([t1, t2]))
    @test_throws ArgumentError replicate_range(db, t1, t1 - Minute(5))

    # Every family is modeled by default: no unmodeled skips, FCAS, interchange losses and storage variables.
    @test !any(in(("unmodeled_fcas_service", "unmodeled_device_type")), string.(result.skipped_constraints.reason))
    var_keys = PSI.list_variable_keys(result.results[1])
    entry_and_component(k) = (PSI.IS.Optimization.get_entry_type(k), PSI.IS.Optimization.get_component_type(k))
    @test any(k -> entry_and_component(k)[1] === FCASCapacityVariable, var_keys)
    @test any(k -> entry_and_component(k) == (InterconnectorLossVariable, PSY.AreaInterchange), var_keys)
    @test any(k -> entry_and_component(k) == (ActivePowerOutVariable, PSY.EnergyReservoirStorage), var_keys)
end

# Whether two stacked comparison NamedTuples hold the same rows (sorted by key) and equal numbers, `missing` included.
function same_comparison(x, y; atol = 1.0e-6)
    same(u, v) = (ismissing(u) && ismissing(v)) || (!ismissing(u) && !ismissing(v) && isapprox(u, v; atol = atol))
    keyed(df) = sort(df, [n for n in names(df) if eltype(df[!, n]) <: Union{Missing, AbstractString, DateTime}])
    return keys(x) == keys(y) && all(keys(x)) do name
        a, b = keyed(getproperty(x, name)), keyed(getproperty(y, name))
        names(a) == names(b) && nrow(a) == nrow(b) && all(
            col -> eltype(a[!, col]) <: Union{Missing, Real} ? all(same.(a[!, col], b[!, col])) : isequal(a[!, col], b[!, col]),
            names(a),
        )
    end
end

@testset "replicate_range chunks" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    @test_throws ArgumentError ReplayWorkflow._range_steps(DateTime(2025, 1, 1), DateTime(2024, 12, 31))
    @test_throws ArgumentError ReplayWorkflow._range_steps(DateTime(2025, 1, 1), DateTime(2025, 1, 1, 0, 7))
    @test ReplayWorkflow._range_steps(DateTime(2025, 1, 1), DateTime(2025, 1, 1)) == DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 1)
    chunks = ReplayWorkflow._range_chunks
    @test chunks(DateTime(2026, 1, 1, 3, 55):Minute(5):DateTime(2026, 1, 1, 4, 15), :trading_day) ==
        [DateTime(2026, 1, 1, 3, 55):Minute(5):DateTime(2026, 1, 1, 4, 0), DateTime(2026, 1, 1, 4, 5):Minute(5):DateTime(2026, 1, 1, 4, 15)]
    @test chunks(DateTime(2026, 1, 1, 4, 5):Minute(5):DateTime(2026, 1, 2, 4, 0), :trading_day) ==
        [DateTime(2026, 1, 1, 4, 5):Minute(5):DateTime(2026, 1, 2, 4, 0)]
    @test chunks(DateTime(2026, 6, 30, 23, 50):Minute(5):DateTime(2026, 7, 1, 0, 15), :trading_day) ==
        [DateTime(2026, 6, 30, 23, 50):Minute(5):DateTime(2026, 7, 1, 0, 0), DateTime(2026, 7, 1, 0, 5):Minute(5):DateTime(2026, 7, 1, 0, 15)]
    @test chunks(DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20), Minute(10)) ==
        [DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 10), DateTime(2025, 1, 1, 0, 15):Minute(5):DateTime(2025, 1, 1, 0, 20)]
    steps = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 10)
    @test_throws ArgumentError chunks(steps, Minute(7))
    @test_throws ArgumentError chunks(steps, Minute(0))
    @test_throws ArgumentError chunks(steps, :calendar_day)
    @test_throws ArgumentError chunks(steps, Month(1))

    # Chunks are a partition of the range; two chunks solve the same intervals as one.
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 20)
    one = replicate_range(db, t1, t2)
    two = replicate_range(db, t1, t2; chunk = Minute(10))
    @test nrow(two.chunks) == 2 && length(two.results) == 2
    @test two.chunks.n_steps == [2, 2]
    @test same_comparison(one.comparison, two.comparison)
    @test nrow(one.solver_stats) == nrow(two.solver_stats) == 4
    @test one.solver_stats.SETTLEMENTDATE == two.solver_stats.SETTLEMENTDATE
    @test one.solver_stats.objective_value ≈ two.solver_stats.objective_value atol = 1.0e-6
    @test two.solver_stats.chunk == [1, 1, 2, 2]
    # Each chunk's reopened results hold its own intervals only.
    t_mid = DateTime(2025, 1, 1, 0, 15)
    @test collect(PSI.get_timestamps(two.results[1])) == collect(t1:Minute(5):(t_mid - Minute(5)))
    @test collect(PSI.get_timestamps(two.results[2])) == collect(t_mid:Minute(5):t2)
    @test PSI.read_optimizer_stats(two.results[2]).objective_value ≈
        filter(:SETTLEMENTDATE => >=(t_mid), one.solver_stats).objective_value atol = 1.0e-6

    # A reopened chunk reads the same constraint violations as the live solve, and needs no system.
    sys2 = workflow_test_system(db, DateTime(2025, 1, 1, 0, 15):Minute(5):DateTime(2025, 1, 1, 0, 25))
    reopened = replication_results(two.results[2], sys2).constraint_violations
    at_chunk2 = filter(:DateTime => t -> t >= DateTime(2025, 1, 1, 0, 15), two.constraint_violations)
    @test sort(reopened, [:DateTime, :name]) == sort(at_chunk2, [:DateTime, :name])

    # The folders hold the stores of each chunk on disk.
    d = mktempdir()
    small = replicate_range(db, t1, DateTime(2025, 1, 1, 0, 10); output_dir = d, cache_size_mib = 16)
    @test isdir(joinpath(d, "chunk_1")) && any(f -> f == "simulation_store.h5", (f for (_, _, fs) in walkdir(joinpath(d, "chunk_1")) for f in fs))
    @test small.chunks.n_steps == [2] && nrow(small.solver_stats) == 2
    # On-disk time series default to a directory inside each chunk folder.
    d = mktempdir()
    replicate_range(db, t1, DateTime(2025, 1, 1, 0, 20); output_dir = d, chunk = Minute(10), time_series_in_memory = false)
    @test all(k -> !isempty(readdir(joinpath(d, "chunk_$k", "time_series"))), 1:2)

    # Every replication time-series parameter is stored, as PowerSimulations stores right-hand-side parameters.
    stored = Set(PSI.IS.Optimization.get_entry_type(k) for k in PSI.list_parameter_keys(one.results[1]))
    @test NEMConstraintRHSParameter in stored
    @test_throws ArgumentError replicate_range(db, t1, DateTime(2025, 1, 1, 0, 10); parts = (:nonsense,))
end


@testset "replicate_range respects parts on the mock cache" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 10)
    result = replicate_range(db, t1, t2; parts = (:generic_constraints,))
    types = Set(PSI.IS.Optimization.get_component_type(k) for k in PSI.list_variable_keys(only(result.results)))
    @test !(PSY.EnergyReservoirStorage in types) && !(PSY.AreaInterchange in types)
    @test !any(k -> PSI.IS.Optimization.get_entry_type(k) === FCASCapacityVariable, PSI.list_variable_keys(only(result.results)))
    @test all(ismissing, result.comparison.interconnectors.MWFLOW_solved)
    @test all(ismissing, result.comparison.fcas_prices.ROP_solved)
    @test any(in((:unmodeled_fcas_service, :unmodeled_device_type)), result.skipped_constraints.reason)
    @test any(!ismissing, result.comparison.dispatch.TOTALCLEARED_solved)
end
