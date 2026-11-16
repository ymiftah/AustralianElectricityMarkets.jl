# The replay workflow over the mock cache: the system (which validates its inputs), the simulation,
# the solved and published comparison, and the chunks of a range. Uses the `replay_chunks` and
# `run_replay` API and the mock hives loaded by `runtests.jl`.

# Replays `steps` as one simulation: the system over `steps` and the two intervals after them (with
# `nem_system` validating its inputs), `run_replay`, then the solved and published comparison. Time
# series are kept on disk in
# `folder/time_series` unless `time_series_in_memory`; `kwargs` go to `run_replay`.
function replay_steps(
        db, steps; intervention::Integer = 0, template::PSI.ProblemTemplate = template_nemde(),
        interval_flow_limits::Bool = false, time_series_in_memory::Bool = true,
        folder::AbstractString = mktempdir(), kwargs...,
    )
    date_range = first(steps):DISPATCH_INTERVAL:(last(steps) + 2DISPATCH_INTERVAL)
    time_series = time_series_in_memory ? (;) : (; time_series_directory = mkpath(joinpath(folder, "time_series")))
    sys = nem_system(
        db, NEMDEConfiguration(); date_range, intervention, interval_flow_limits, time_series_in_memory, time_series...,
    )
    replay = run_replay(sys, steps; template, folder, kwargs...)
    solved = read_solved_interval(replay.results, sys)
    comparison = compare_intervals(read_published_interval(db, steps; intervention), solved)
    violations = read_constraint_violations(replay.results, sys)
    stats = PSI.read_optimizer_stats(replay.results)
    solver_stats = DataFrame(
        SETTLEMENTDATE = collect(steps), objective_value = stats.objective_value,
        timed_solve_time = stats.timed_solve_time, termination_status = stats.termination_status,
    )
    return (;
        sys, results = replay.results, skipped = replay.skipped_constraints, comparison,
        violations, solver_stats,
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

@testset "a replay of a range over the mock cache" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 10)
    result = replay_steps(db, t1:DISPATCH_INTERVAL:t2)
    # The mock system leaves no constraint out under the full template.
    @test isempty(result.skipped)
    c = result.comparison
    # One row per published key, so nothing is dropped silently.
    for table in (:prices, :dispatch, :interconnectors, :fcas_prices)
        @test first(names(c[table])) == "SETTLEMENTDATE" && Set(c[table].SETTLEMENTDATE) == Set([t1, t2])
        @test nrow(c[table]) == sum(nrow(read_published_interval(db, t)[table]) for t in (t1, t2))
    end
    @test issubset(Set(["NSW1", "QLD1", "SA1", "TAS1", "VIC1"]), Set(c.prices.REGIONID))
    @test all(isfinite, skipmissing(c.prices.ROP_solved)) && any(!ismissing, c.prices.ROP_solved)
    @test any(!ismissing, c.dispatch.TOTALCLEARED_solved)
    # The scheduled load PUMP1 is solved, as a non-negative consumed MW.
    @test all(mw -> !ismissing(mw) && mw >= 0, filter(:DUID => ==("PUMP1"), c.dispatch).TOTALCLEARED_solved)
    # Interchanges are modeled (the unavailable IC6 is not), and so is FCAS, the 1-second markets included.
    @test any(!ismissing, c.interconnectors.MWFLOW_solved)
    @test all(isfinite, skipmissing(c.interconnectors.MWLOSSES_solved))
    @test all(ismissing, filter(:INTERCONNECTORID => ==("IC6"), c.interconnectors).MWFLOW_solved)
    @test all(isfinite, skipmissing(c.fcas_prices.ROP_solved))
    for bid_type in (BidType.RAISE1SEC, BidType.LOWER1SEC)
        @test any(!ismissing, filter(:BIDTYPE => ==(bid_type), c.fcas_prices).ROP_solved)
    end
    # Invoked at 00:10 only over BW01-BW04: modeled now that batteries are, and masked at 00:05.
    duals = stock_gc_duals(result.results)
    partial = only(k for k in keys(duals) if startswith(k, "N_PARTIAL_COVERAGE"))
    @test duals[partial][t1] == 0.0
    @test any(!ismissing, c.dispatch.TOTALCLEARED_solved[c.dispatch.DUID .== "BW01"])
    # The MNSP IC2 is modeled with its link offers in both steps.
    links = only(values(PSI.read_realized_variables(result.results, ["MNSPLinkFlowVariable__AreaInterchange"])))
    @test Set(links.DateTime) == Set([t1, t2]) && all(>=(-1.0e-9), links.value)
    @test issubset(Set(result.violations.DateTime), Set([t1, t2]))
    # Every family is modeled by default: FCAS, interchange losses and storage variables.
    var_keys = PSI.list_variable_keys(result.results)
    entry_and_component(k) = (PSI.IS.Optimization.get_entry_type(k), PSI.IS.Optimization.get_component_type(k))
    @test any(k -> entry_and_component(k)[1] === FCASCapacityVariable, var_keys)
    @test any(k -> entry_and_component(k) == (InterconnectorLossVariable, PSY.AreaInterchange), var_keys)
    @test any(k -> entry_and_component(k) == (ActivePowerOutVariable, EnergyReservoirStorage), var_keys)
end

@testset "replay_chunks splits a replay into simulations" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 20)
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
    sys2 = nem_system(db, NEMDEConfiguration(); date_range = DateTime(2025, 1, 1, 0, 15):Minute(5):DateTime(2025, 1, 1, 0, 25))
    reopened = PSI.get_decision_problem_results(PSI.SimulationResults(two.chunks.folder[2], "replication"), "dispatch")
    at_chunk2 = filter(:DateTime => t -> t >= t_mid, two.violations)
    @test sort(read_constraint_violations(reopened, sys2), [:DateTime, :name]) == sort(at_chunk2, [:DateTime, :name])

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
    for T in (ThermalStandard, HydroDispatch, RenewableDispatch, InterruptiblePowerLoad, EnergyReservoirStorage)
        PSI.set_device_model!(template, T, AEMS.NEMReplayDispatch)
    end
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_service_model!(
        template,
        PSI.ServiceModel(GenericConstraint, LinearFactorLimit; duals = [NEMConstraintLimit], use_slacks = true),
    )
    result = replay_steps(db, t1:DISPATCH_INTERVAL:t2; template)
    types = Set(PSI.IS.Optimization.get_component_type(k) for k in PSI.list_variable_keys(result.results))
    @test EnergyReservoirStorage in types && !(PSY.AreaInterchange in types)
    @test !any(k -> PSI.IS.Optimization.get_entry_type(k) === FCASCapacityVariable, PSI.list_variable_keys(result.results))
    @test all(ismissing, result.comparison.interconnectors.MWFLOW_solved)
    @test all(ismissing, result.comparison.fcas_prices.ROP_solved)
    @test any(in((:unmodeled_fcas_service, :unmodeled_device_type)), result.skipped.reason)
    @test any(!ismissing, result.comparison.dispatch.TOTALCLEARED_solved)
end
