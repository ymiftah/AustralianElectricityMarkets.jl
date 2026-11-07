# The replay workflow over the mock cache: pre-flight checks, the system, the simulation, the solved
# and published comparison, and the chunks of a range. Uses the `replay_chunks` and `run_replay` API
# and the mock hives loaded by `runtests.jl`.

# Replays `steps` as one simulation: pre-flight checks, the system over `steps` and the two intervals
# after them, `run_replay`, then the solved and published comparison. Time series are kept on disk in
# `folder/time_series` unless `time_series_in_memory`; `kwargs` go to `run_replay`.
function replay_steps(
        db, steps; intervention::Integer = 0, template::PSI.ProblemTemplate = template_nemde(),
        interval_flow_limits::Bool = false, time_series_in_memory::Bool = true,
        folder::AbstractString = mktempdir(), kwargs...,
    )
    date_range = first(steps):DISPATCH_INTERVAL:(last(steps) + 2DISPATCH_INTERVAL)
    check_replay_inputs(db, date_range; intervention, template)
    time_series = time_series_in_memory ? (;) : (; time_series_directory = mkpath(joinpath(folder, "time_series")))
    sys = nem_system(
        db, NEMDEConfiguration(); date_range, intervention, interval_flow_limits, time_series_in_memory, time_series...,
    )
    replay = run_replay(sys, steps; template, folder, kwargs...)
    solved = read_solved_interval(replay.results, sys)
    comparison = compare_intervals(read_published_interval(db, steps; intervention), solved)
    violations = read_constraint_violations(replay.results, sys)
    ramp = select(filter(:family => ==("unit_ramp"), violations), :name => :DUID, :DateTime, :MW, :direction)
    stats = PSI.read_optimizer_stats(replay.results)
    solver_stats = DataFrame(
        SETTLEMENTDATE = collect(steps), objective_value = stats.objective_value,
        timed_solve_time = stats.timed_solve_time, termination_status = stats.termination_status,
    )
    return (;
        sys, results = replay.results, skipped = replay.skipped_constraints, comparison,
        violations, ramp, solver_stats,
    )
end

# `replay_steps` over each chunk of `replay_chunks(steps; chunk)`, with the tables of the chunks stacked.
# Each chunk writes to `output_dir/chunk_<k>` when `output_dir` is given.
function replay_chunked(db, steps; chunk = :trading_day, output_dir = nothing, kwargs...)
    chunks = replay_chunks(steps; chunk)
    folders = [
        isnothing(output_dir) ? mktempdir() : mkpath(joinpath(output_dir, "chunk_$k")) for k in eachindex(chunks)
    ]
    outs = [replay_steps(db, c; folder, kwargs...) for (c, folder) in zip(chunks, folders)]
    stacked(table) = reduce(vcat, [getproperty(out.comparison, table) for out in outs])
    return (;
        chunks = DataFrame(chunk = eachindex(chunks), n_steps = length.(chunks), folder = folders),
        results = [out.results for out in outs],
        comparison = NamedTuple(table => stacked(table) for table in keys(first(outs).comparison)),
        violations = reduce(vcat, [out.violations for out in outs]),
        solver_stats = reduce(vcat, [insertcols(out.solver_stats, :chunk => fill(k, nrow(out.solver_stats))) for (k, out) in enumerate(outs)]),
    )
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

# A system over `date_range` with its forecast windows attached, for reading the results of a replay.
function prepared_test_system(db, date_range)
    return AEMS._prepare_replay_forecasts!(nem_system(db, NEMDEConfiguration(); date_range))
end

@testset "simulation runtime exposes no cache entry points" begin
    for api in (:replication_system, :read_interval_inputs, :read_published_interval, :aem_connect)
        @test !isdefined(AEMS, api)
    end
end

# Results that list an interconnector flow variable and no loss variable.
struct FlowWithoutLossResults end
PSI.list_variable_keys(::FlowWithoutLossResults) = [PSI.VariableKey(PSI.FlowActivePowerVariable, PSY.AreaInterchange)]

@testset "read_solved_interval rejects interconnector flows without losses" begin
    @test_throws ArgumentError read_solved_interval(FlowWithoutLossResults(), PSY.System(100.0))
end

@testset "Replication pipeline" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    t = DateTime(2025, 1, 1, 0, 5, 0)

    @testset "a replay over the mock cache solves and compares" begin
        result = replay_steps(db, t:DISPATCH_INTERVAL:t)
        @test result.results isa PSI.SimulationProblemResults
        @test names(result.skipped) == ["constraint", "reason", "n_missing"]
        @test all(in((:no_available_device, :never_invoked)), result.skipped.reason)
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
        sys = prepared_test_system(db, t:Minute(5):(t + Minute(10)))
        ic2 = get_component(AreaInterchange, sys, "IC2")
        @test !isempty(get_supplemental_attributes(AustralianElectricityMarkets.NEMMNSPBid, ic2))
        result = replay_steps(db, t:DISPATCH_INTERVAL:t; interval_flow_limits = true)
        @test any(
            k -> PSI.IS.Optimization.get_entry_type(k) === MNSPLinkFlowVariable,
            PSI.list_variable_keys(result.results),
        )
        flow = only(filter(:INTERCONNECTORID => ==("IC2"), result.comparison.interconnectors)).MWFLOW_solved
        @test abs(flow) <= 300.0 + 1.0e-6
    end
end

@testset "a replay of a range over the mock cache" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 10)
    result = replay_steps(db, t1:DISPATCH_INTERVAL:t2)
    @test length(replay_chunks(t1:DISPATCH_INTERVAL:t2)) == 1
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
    @test !any(startswith("N_PARTIAL_COVERAGE"), result.skipped.constraint)
    duals = stock_gc_duals(result.results)
    partial = only(k for k in keys(duals) if startswith(k, "N_PARTIAL_COVERAGE"))
    @test duals[partial][t1] == 0.0
    @test any(!ismissing, c.dispatch.TOTALCLEARED_solved[c.dispatch.DUID .== "BW01"])
    # The MNSP IC2 is modeled with its link offers in both steps.
    links = only(values(PSI.read_realized_variables(result.results, ["MNSPLinkFlowVariable__AreaInterchange"])))
    @test Set(links.DateTime) == Set([t1, t2]) && all(>=(-1.0e-9), links.value)
    @test names(result.ramp) == ["DUID", "DateTime", "MW", "direction"]
    @test issubset(Set(result.violations.DateTime), Set([t1, t2]))

    # Every family is modeled by default: no unmodeled skips, FCAS, interchange losses and storage variables.
    @test !any(in(("unmodeled_fcas_service", "unmodeled_device_type")), string.(result.skipped.reason))
    var_keys = PSI.list_variable_keys(result.results)
    entry_and_component(k) = (PSI.IS.Optimization.get_entry_type(k), PSI.IS.Optimization.get_component_type(k))
    @test any(k -> entry_and_component(k)[1] === FCASCapacityVariable, var_keys)
    @test any(k -> entry_and_component(k) == (InterconnectorLossVariable, PSY.AreaInterchange), var_keys)
    @test any(k -> entry_and_component(k) == (ActivePowerOutVariable, NEMStorage), var_keys)
end

@testset "replay_chunks splits a replay into simulations" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 20)
    @test_throws ArgumentError replay_chunks(t1:DISPATCH_INTERVAL:t2; chunk = Minute(7))
    # Chunks are a partition of the range; two chunks solve the same intervals as one.
    one = replay_chunked(db, t1:DISPATCH_INTERVAL:t2)
    two = replay_chunked(db, t1:DISPATCH_INTERVAL:t2; chunk = Minute(10))
    @test nrow(two.chunks) == 2 && length(two.results) == 2
    @test two.chunks.n_steps == [2, 2]
    @test same_comparison(one.comparison, two.comparison)
    @test nrow(one.solver_stats) == nrow(two.solver_stats) == 4
    @test one.solver_stats.SETTLEMENTDATE == two.solver_stats.SETTLEMENTDATE
    @test one.solver_stats.objective_value ≈ two.solver_stats.objective_value atol = 1.0e-6
    @test two.solver_stats.chunk == [1, 1, 2, 2]
    # Each chunk's results hold its own intervals only.
    t_mid = DateTime(2025, 1, 1, 0, 15)
    @test collect(PSI.get_timestamps(two.results[1])) == collect(t1:Minute(5):(t_mid - Minute(5)))
    @test collect(PSI.get_timestamps(two.results[2])) == collect(t_mid:Minute(5):t2)
    @test PSI.read_optimizer_stats(two.results[2]).objective_value ≈
        filter(:SETTLEMENTDATE => >=(t_mid), one.solver_stats).objective_value atol = 1.0e-6

    # The reopened results of a chunk read the same constraint violations as its live solve, and need no system.
    sys2 = prepared_test_system(db, DateTime(2025, 1, 1, 0, 15):Minute(5):DateTime(2025, 1, 1, 0, 25))
    reopened = PSI.get_decision_problem_results(PSI.SimulationResults(two.chunks.folder[2], "replication"), "dispatch")
    at_chunk2 = filter(:DateTime => t -> t >= t_mid, two.violations)
    @test sort(read_constraint_violations(reopened, sys2), [:DateTime, :name]) == sort(at_chunk2, [:DateTime, :name])

    # The folders hold the stores of each chunk on disk.
    d = mktempdir()
    small = replay_chunked(db, t1:DISPATCH_INTERVAL:DateTime(2025, 1, 1, 0, 10); output_dir = d, cache_size_mib = 16)
    @test isdir(joinpath(d, "chunk_1")) && any(f -> f == "simulation_store.h5", (f for (_, _, fs) in walkdir(joinpath(d, "chunk_1")) for f in fs))
    @test small.chunks.n_steps == [2] && nrow(small.solver_stats) == 2
    # On-disk time series default to a directory inside each chunk folder.
    d = mktempdir()
    replay_chunked(db, t1:DISPATCH_INTERVAL:t2; output_dir = d, chunk = Minute(10), time_series_in_memory = false)
    @test all(k -> !isempty(readdir(joinpath(d, "chunk_$k", "time_series"))), 1:2)

    # Every replication time-series parameter is stored, as PowerSimulations stores right-hand-side parameters.
    stored = Set(PSI.IS.Optimization.get_entry_type(k) for k in PSI.list_parameter_keys(one.results[1]))
    @test NEMConstraintRHSParameter in stored
end

@testset "a replay of the given template on the mock cache" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 10)
    # The dispatch participants and static demand of `template_nemde`, with generic constraints only.
    template = PSI.ProblemTemplate(
        PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true, duals = [PSI.CopperPlateBalanceConstraint]),
    )
    for T in (NEMThermalGen, NEMHydroGen, NEMRenewableGen, NEMLoad, NEMStorage)
        PSI.set_device_model!(template, T, AEMS.NEMReplayDispatch)
    end
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_service_model!(
        template,
        PSI.ServiceModel(GenericConstraint, LinearFactorLimit; duals = [NEMConstraintLimit], use_slacks = true),
    )
    result = replay_steps(db, t1:DISPATCH_INTERVAL:t2; template)
    types = Set(PSI.IS.Optimization.get_component_type(k) for k in PSI.list_variable_keys(result.results))
    @test NEMStorage in types && !(PSY.AreaInterchange in types)
    @test !any(k -> PSI.IS.Optimization.get_entry_type(k) === FCASCapacityVariable, PSI.list_variable_keys(result.results))
    @test all(ismissing, result.comparison.interconnectors.MWFLOW_solved)
    @test all(ismissing, result.comparison.fcas_prices.ROP_solved)
    @test any(in((:unmodeled_fcas_service, :unmodeled_device_type)), result.skipped.reason)
    @test any(!ismissing, result.comparison.dispatch.TOTALCLEARED_solved)
end

@testset "check_replay_inputs checks exact padded coverage and versions" begin
    t = DateTime(2025, 1, 1, 0, 5)
    grid = collect(t:Minute(5):(t + Minute(5)))
    links = DataFrame(INTERCONNECTORID = ["M", "M"], LINKID = ["F", "R"])
    offers = DataFrame(LINKID = ["F", "R", "F", "R"], INTERVAL_DATETIME = [grid[1], grid[1], grid[2], grid[2]])
    @test isnothing(AEMS._check_mnsp_coverage(links, offers, ["M"], grid))
    @test_throws ArgumentError AEMS._check_mnsp_coverage(links, offers[1:3, :], ["M"], grid)
    @test_throws ArgumentError AEMS._check_mnsp_coverage(links, vcat(offers, offers[1:1, :]), ["M"], grid)
    @test_throws ArgumentError AEMS._check_mnsp_coverage(links[1:1, :], offers, ["M"], grid)
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR))
    @test isnothing(check_replay_inputs(db, t:Minute(5):(t + Minute(10)); template = template_nemde()))
end

@testset "check_replay_inputs preserves fixed-load and built-in constraint handling" begin
    t = DateTime(2025, 1, 1, 0, 5)
    eff = DateTime(2020, 1, 1)
    invoked = DataFrame(
        GENCONID = ["C", "\$U"], SETTLEMENTDATE = [t, t],
        GENCONID_EFFECTIVEDATE = [eff, eff], GENCONID_VERSIONNO = [1, 1]
    )
    fixed = DataFrame(DUID = ["U"], INTERVAL_DATETIME = [t])
    definitions = DataFrame(GENCONID = ["C"], EFFECTIVEDATE = [eff], VERSIONNO = [1])
    @test isnothing(AEMS._check_constraint_versions(invoked, fixed, definitions))
    definitions.VERSIONNO .= 2
    @test_throws ArgumentError AEMS._check_constraint_versions(invoked, fixed, definitions)
    builtin = first(keys(AustralianElectricityMarkets._ZERO_FLOW_CONSTRAINTS))
    invoked = DataFrame(
        GENCONID = [builtin], SETTLEMENTDATE = [t],
        GENCONID_EFFECTIVEDATE = [DateTime(AustralianElectricityMarkets._ZERO_FLOW_EFFECTIVEDATE)],
        GENCONID_VERSIONNO = [AustralianElectricityMarkets._ZERO_FLOW_VERSIONNO]
    )
    @test isnothing(AEMS._check_constraint_versions(invoked, fixed, definitions[1:0, :]))
end

@testset "check_replay_inputs needs no GENCONDATA for fixed-load-only units" begin
    db = damaged_cache(
        AEM_TEST_REPLAY_HIVE_DIR, :DISPATCHCONSTRAINT,
        "UPDATE input SET CONSTRAINTID = '\$BW01'"
    )
    fixed_db = damaged_cache(
        db.config.hive_location, :BIDPEROFFER_D,
        "UPDATE input SET FIXEDLOAD = 1.0 WHERE DUID = 'BW01' AND BIDTYPE = 'ENERGY'"
    )
    rm(joinpath(fixed_db.config.hive_location, "GENCONDATA"); recursive = true)
    t = DateTime(2025, 1, 1, 0, 5)
    @test isnothing(check_replay_inputs(fixed_db, t:Minute(5):(t + Minute(10))))
end
