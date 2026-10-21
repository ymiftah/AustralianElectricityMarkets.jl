module ReplayWorkflow

using AustralianElectricityMarkets
using AustralianElectricityMarketsSimulations
using DataFrames
using Dates
using HiGHS
import PowerSimulations as PSI

export replicate_range

const _REPLICATION_HORIZON = 2DISPATCH_INTERVAL
const _DEFAULT_OPTIMIZER = PSI.optimizer_with_attributes(
    HiGHS.Optimizer, "mip_rel_gap" => 0.0, "mip_abs_gap" => 1.0e-10,
)

function _log_skipped_constraints(skipped::DataFrame)
    by_reason = combine(groupby(skipped, :reason), nrow => :n)
    counts = join(("$(r.reason)=$(r.n)" for r in eachrow(sort(by_reason, :reason))), ", ")
    @error "Skipped constraints at failure: $(nrow(skipped)) ($counts)" skipped
    return
end


# `start:5 min:stop`; throws unless `stop` is `start` plus a whole number of intervals.
function _range_steps(start::DateTime, stop::DateTime)
    steps = start:DISPATCH_INTERVAL:stop
    (stop >= start && last(steps) == stop) || throw(
        ArgumentError(
            "replicate_range: stop ($stop) must be start ($start) plus a whole number of $DISPATCH_INTERVAL intervals.",
        ),
    )
    return steps
end


# One range per chunk of `steps`: a chunk starts at the first step, at every 04:05 trading-day
# start, at 00:05 on 1 July and, with a `Dates.Period` `chunk`, every `chunk` after its own start.
function _range_chunks(steps::StepRange{DateTime}, chunk::Union{Symbol, Dates.Period})
    _check_chunk(chunk)
    starts = DateTime[]
    for t in steps
        starts_trading_day = Time(t) == Time(4, 5)
        starts_financial_year = month(t) == 7 && day(t) == 1 && Time(t) == Time(0, 5)
        periodic = chunk isa Dates.Period && !isempty(starts) && t - last(starts) >= chunk
        (isempty(starts) || starts_trading_day || starts_financial_year || periodic) && push!(starts, t)
    end
    stops = [starts[2:end] .- DISPATCH_INTERVAL; last(steps)]
    return [a:DISPATCH_INTERVAL:b for (a, b) in zip(starts, stops)]
end


# `chunk` is `:trading_day` or a positive whole number of dispatch intervals.
function _check_chunk(chunk)
    chunk === :trading_day && return
    fixed = chunk isa Union{Dates.Week, Dates.Day, Dates.Hour, Dates.Minute, Dates.Second, Dates.Millisecond}
    ms = fixed ? Dates.value(Dates.Millisecond(chunk)) : 0
    (fixed && ms > 0 && ms % Dates.value(Dates.Millisecond(DISPATCH_INTERVAL)) == 0) || throw(
        ArgumentError("replicate_range: chunk must be :trading_day or a positive multiple of $DISPATCH_INTERVAL, got $chunk."),
    )
    return
end


# Every published row of `steps` with its solved value, `missing` where the model has none. Every
# table is keyed by `SETTLEMENTDATE` and its own key column.
function _compare_to_published(published, solved, steps)
    at_steps(df) = filter(:SETTLEMENTDATE => in(Set(steps)), df)
    compare(table, on) = leftjoin(
        at_steps(published[table]), at_steps(solved[table]);
        on = [:SETTLEMENTDATE, on], renamecols = "_published" => "_solved",
    )
    return (;
        prices = compare(:prices, :REGIONID),
        dispatch = compare(:dispatch, :DUID),
        interconnectors = compare(:interconnectors, :INTERCONNECTORID),
        fcas_prices = leftjoin(
            at_steps(select(published.fcas_prices, :SETTLEMENTDATE, :REGIONID, :BIDTYPE, :ROP)),
            at_steps(solved.fcas_prices); on = [:SETTLEMENTDATE, :REGIONID, :BIDTYPE], renamecols = "_published" => "_solved",
        ),
    )
end


# One chunk of `replicate_range`: system, simulation, execution, comparison and violations. Only
# the tables and the results reopened from `folder` are returned, so the system is collectable.
function _replicate_chunk(
        db, steps, k::Integer; intervention::Integer, optimizer, parts, interval_flow_limits::Bool, folder::AbstractString,
        time_series_in_memory::Bool, time_series_directory, cache_size_mib,
    )
    t0 = time()
    ts_directory = time_series_in_memory ? nothing : something(time_series_directory, joinpath(folder, "time_series"))
    time_series_in_memory || mkpath(ts_directory)
    sys = nem_system(
        db, ReplayNetworkConfiguration(); date_range = first(steps):DISPATCH_INTERVAL:(last(steps) + _REPLICATION_HORIZON),
        intervention = intervention, interval_flow_limits = interval_flow_limits,
        time_series_in_memory = time_series_in_memory, time_series_directory = ts_directory,
    )
    prepare_replication!(sys)
    system_build_s = time() - t0
    t1 = time()
    skipped = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int}[]
    simulation = replication_simulation(sys, steps; optimizer, parts, folder, skipped)
    skipped_constraints = DataFrame(skipped)
    status = PSI.build!(simulation; store_systems_in_results = false)
    status == PSI.SimulationBuildStatus.BUILT || begin
        _log_skipped_constraints(skipped_constraints)
        error("Range from $(first(steps)) failed to build ($status); see the logs in $folder.")
    end
    simulation_build_s = time() - t1
    t2 = time()
    live = try
        kwargs = isnothing(cache_size_mib) ? (;) : (; cache_size_mib)
        status = PSI.execute!(simulation; kwargs...)
        status == PSI.RunStatus.SUCCESSFULLY_FINALIZED || error("Range from $(first(steps)) failed to execute ($status); see the logs in $folder.")
        PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch")
    catch
        _log_skipped_constraints(skipped_constraints)
        rethrow()
    end
    execute_s = time() - t2
    t3 = time()
    report = replication_results(live, sys; parts)
    solved = report.solved
    comparison = _compare_to_published(read_published_interval(db, steps; intervention = intervention), solved, steps)
    violations = report.constraint_violations
    stats = PSI.read_optimizer_stats(live)
    nrow(stats) == length(steps) || error("Chunk $k: $(nrow(stats)) optimizer stat rows for $(length(steps)) steps.")
    solver_stats = DataFrame(
        SETTLEMENTDATE = collect(steps), chunk = fill(k, length(steps)),
        objective_value = stats.objective_value, solver_solve_time = stats.solver_solve_time,
        timed_solve_time = stats.timed_solve_time,
        timed_calculate_dual_variables = stats.timed_calculate_dual_variables,
        termination_status = stats.termination_status,
    )
    compare_s = time() - t3
    reopened = PSI.get_decision_problem_results(PSI.SimulationResults(folder, "replicate_range"), "dispatch")
    return (;
        timings = (; system_build_s, simulation_build_s, execute_s, compare_s), results = reopened,
        comparison, skipped_constraints = insertcols(skipped_constraints, 1, :chunk => fill(k, nrow(skipped_constraints))),
        constraint_violations = violations, ramp_violations = report.ramp_violations, solver_stats,
    )
end


"""
    replicate_range(db, start, stop; intervention = 0, optimizer = _DEFAULT_OPTIMIZER, parts = REPLICATION_PARTS,
        chunk = :trading_day, interval_flow_limits = false, output_dir = nothing, time_series_in_memory = true,
        time_series_directory = nothing, cache_size_mib = nothing) -> NamedTuple

Replays the historical NEM dispatch intervals `start:5 minutes:stop` and compares each with AEMO's
published outcome. Each chunk of the range is one `PowerSimulations.Simulation`: a one-interval
[`replication_template`](@ref) model is built once on a `nem_system(db, ReplayNetworkConfiguration(); ...)` over the chunk
and stepped through its intervals, its parameters updating at each step, and every step starts from
the interval's published `INITIALMW`. A chunk starts at `start`, at every 04:05 trading-day start, at
00:05 on 1 July and, with a `Dates.Period` `chunk`, every `chunk` after its own start. Each chunk
leaves out the generic constraints invoked at none of its intervals, prices violations at each
interval's Market Price Cap, and checks before its build that its intervals share the same price-tied band pairs
([`check_tie_break_pairs`](@ref)) and a feasible dispatch envelope ([`check_dispatch_envelope`](@ref)).

# Arguments
- `db`: an `AEMDB` connection whose cache holds the tables of `ReplayNetworkConfiguration` plus
  `DISPATCHINTERCONNECTORRES`, from `start` to `stop + 10 minutes`.
- `start`, `stop`: `SETTLEMENTDATE`s a whole number of 5-minute intervals apart; `start == stop`
  replays one interval.
- `intervention`: 0 for the pricing run, 1 for the physical run.
- `optimizer`: the JuMP optimizer, e.g. `optimizer_with_attributes(HiGHS.Optimizer, ...)`. Defaults
  to HiGHS with `mip_rel_gap = 0` and `mip_abs_gap = 1e-10`, since the interconnector loss encoding is a MILP.
- `parts`: the [`REPLICATION_PARTS`](@ref) to model; default all.
- `chunk`: `:trading_day` or a `Dates.Period` that is a positive multiple of 5 minutes.
- `interval_flow_limits`: as in `nem_system(db, ReplayNetworkConfiguration(); ...)`; default `false`.
- `output_dir`: a directory for the chunk folders `chunk_<k>`; `nothing` uses a fresh `mktempdir()` per chunk.
- `time_series_in_memory`, `time_series_directory`: passed to `nem_system(db, ReplayNetworkConfiguration(); ...)`;
  `time_series_directory = nothing` writes each chunk's time-series file under `<chunk folder>/time_series`.
- `cache_size_mib`: the simulation store's write cache in MiB; `nothing` keeps PowerSimulations' default.

# Returns
A `NamedTuple` of
- `chunks`: a `DataFrame` with one row per chunk: `chunk`, `start`, `stop`, `n_steps`, `folder`,
  `system_build_s`, `simulation_build_s`, `execute_s` and `compare_s` (seconds).
- `results`: a `Vector` of the `PSI.SimulationProblemResults` of each chunk, reopened from its folder.
- `skipped_constraints`: a `DataFrame` with one row per generic constraint a chunk left out:
  `chunk`, `constraint`, `reason` (`:no_available_device` when all its contributing devices are
  unavailable, `:never_invoked` when invoked at none of the chunk's intervals, or the reason a
  left-out part gives) and `n_missing`.
- `comparison`: a `NamedTuple` of `DataFrame`s with one row per published key and interval and
  `_solved` and `_published` columns, `missing` where the model has no solved value: `prices`
  (`SETTLEMENTDATE`, `REGIONID`; solved `ROP`, published `ROP` and `RRP`), `dispatch` (`DUID`,
  `TOTALCLEARED`), `interconnectors` (`INTERCONNECTORID`, `MWFLOW`, `MWLOSSES`) and `fcas_prices`
  (`REGIONID`, `BIDTYPE`, `ROP`). The solved balance dual is the unadjusted price, so it is compared
  with `ROP`; `RRP` differs only under an administered price.
- `constraint_violations`: every non-zero slack (`family`, `name`, `DateTime`, `MW`, `direction`,
  `variable`), where `family` is one of `"unit_ramp"`, `"interconnector_flow"`, `"fcas_max_avail"`,
  `"fcas_bdu_ramping"`, `"fcas_joint_ramping"`, `"fcas_enablement"`, `"generic_constraint"` (at an
  interval where the constraint is invoked) and `"area_balance"`. `direction` is `"up"` for a slack
  relaxing a `<=` row and `"down"` for one relaxing a `>=` row; for `"area_balance"`, an equality,
  `"up"` is a deficit (demand left unserved) and `"down"` a surplus. The tie-break slacks are not listed.
- `ramp_violations`: the `"unit_ramp"` rows as `DUID`, `DateTime`, `MW` and `direction`.
- `solver_stats`: a `DataFrame` with one row per interval: `SETTLEMENTDATE`, `chunk`, `objective_value`,
  `solver_solve_time`, `timed_solve_time`, `timed_calculate_dual_variables` and `termination_status`.

The FCAS `ROP_solved` is `missing` unless `parts` includes `:fcas` and `:generic_constraints`, and
`MWFLOW_solved`/`MWLOSSES_solved` are `missing` unless `parts` includes `:losses`. Throws
`ArgumentError` on an unknown part, a `stop` that is not `start` plus whole intervals, a bad `chunk`
or a chunk that fails its pre-flight checks, and rethrows the error of a chunk that fails to build or
execute after logging its skipped constraints and the folders of the chunks already solved.
"""
function replicate_range(
        db, start::DateTime, stop::DateTime; intervention::Integer = 0,
        optimizer = _DEFAULT_OPTIMIZER, parts = REPLICATION_PARTS, chunk = :trading_day,
        interval_flow_limits::Bool = false, output_dir::Union{Nothing, AbstractString} = nothing, time_series_in_memory::Bool = true,
        time_series_directory::Union{Nothing, AbstractString} = nothing,
        cache_size_mib::Union{Nothing, Integer} = nothing,
    )
    unknown = setdiff(parts, REPLICATION_PARTS)
    isempty(unknown) || throw(ArgumentError("replicate_range: unknown parts $(Tuple(unknown)); choose from $REPLICATION_PARTS."))
    chunks = _range_chunks(_range_steps(start, stop), chunk)
    folders = String[]
    outs = map(enumerate(chunks)) do (k, steps)
        folder = isnothing(output_dir) ? mktempdir() : mkpath(joinpath(output_dir, "chunk_$k"))
        push!(folders, folder)
        try
            return _replicate_chunk(
                db, steps, k; intervention = intervention, optimizer = optimizer, parts = parts,
                interval_flow_limits = interval_flow_limits, folder = folder, time_series_in_memory = time_series_in_memory,
                time_series_directory = time_series_directory, cache_size_mib = cache_size_mib,
            )
        catch
            @error "replicate_range: chunk $k ($(first(steps)) to $(last(steps))) failed; solved chunk folders: $(folders[1:(end - 1)])"
            rethrow()
        end
    end
    stacked(field) = reduce(vcat, [getproperty(out, field) for out in outs])
    chunk_table = DataFrame(
        chunk = eachindex(chunks), start = first.(chunks), stop = last.(chunks), n_steps = length.(chunks),
        folder = folders,
    )
    for field in (:system_build_s, :simulation_build_s, :execute_s, :compare_s)
        chunk_table[!, field] = [getproperty(out.timings, field) for out in outs]
    end
    return (;
        chunks = chunk_table,
        results = [out.results for out in outs],
        skipped_constraints = stacked(:skipped_constraints),
        comparison = NamedTuple(
            table => reduce(vcat, [getproperty(out.comparison, table) for out in outs])
                for table in keys(first(outs).comparison)
        ),
        ramp_violations = stacked(:ramp_violations),
        constraint_violations = stacked(:constraint_violations),
        solver_stats = stacked(:solver_stats),
    )
end

end
