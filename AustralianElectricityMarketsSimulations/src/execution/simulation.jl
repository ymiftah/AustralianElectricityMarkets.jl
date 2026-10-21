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


# Available `GenericConstraint`s invoked at none of `steps`, each mapped to `:never_invoked`.
function _never_invoked_constraints(sys::PSY.System, steps)
    reasons = Dict{String, Symbol}()
    for gc in PSY.get_components(PSY.get_available, GenericConstraint, sys)
        invoked = PSY.get_time_series_values(
            PSY.SingleTimeSeries, gc, "invoked"; start_time = first(steps), len = length(steps),
        )
        all(iszero, invoked) && (reasons[PSY.get_name(gc)] = :never_invoked)
    end
    return reasons
end


# Pre-flight checks, template and built `PSI.Simulation` of a one-interval `DecisionModel` stepping
# through `steps`: the template keeps the constraints invoked at some step, and a model built once
# requires the same tied band pairs and a feasible dispatch envelope at every step.
function _build_range_simulation(
        sys::PSY.System, steps; optimizer = _DEFAULT_OPTIMIZER, parts = REPLICATION_PARTS,
        folder::AbstractString = mktempdir(), name = "dispatch",
    )
    :tie_breaks in parts && check_tie_break_pairs(sys, steps)
    template_skipped = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int}[]
    exclude = :generic_constraints in parts ? _never_invoked_constraints(sys, steps) : Dict{String, Symbol}()
    template = replication_template(sys; skipped = template_skipped, parts = parts, exclude_constraints = exclude)
    skipped_constraints = DataFrame(template_skipped)
    check_fcas_services(sys, template; excluded_device_types = :batteries in parts ? () : (PSY.Storage,))
    check_dispatch_envelope(sys, template, first(steps), length(steps))
    model = _replication_decision_model(template, sys, first(steps); optimizer = optimizer, name = name)
    models = PSI.SimulationModels(; decision_models = [model])
    sequence = PSI.SimulationSequence(; models = models, ini_cond_chronology = PSI.InterProblemChronology())
    simulation = PSI.Simulation(;
        name = "replicate_range", steps = length(steps), models = models,
        sequence = sequence, simulation_folder = folder, initial_time = first(steps),
    )
    status = Base.CoreLogging.with_logger(
        () -> PSI.build!(simulation; store_systems_in_results = false), _DropMILPWarning(),
    )
    status == PSI.SimulationBuildStatus.BUILT || begin
        _log_skipped_constraints(skipped_constraints)
        error("Range from $(first(steps)) failed to build ($status); see the logs in $folder.")
    end
    return (; simulation, model, skipped_constraints)
end


# Executes a built simulation and returns the results of its decision problem `name`.
function _execute_range_simulation(simulation::PSI.Simulation; name = "dispatch", cache_size_mib = nothing)
    kwargs = isnothing(cache_size_mib) ? (;) : (; cache_size_mib = cache_size_mib)
    status = PSI.execute!(simulation; kwargs...)
    status == PSI.RunStatus.SUCCESSFULLY_FINALIZED ||
        error("Range from $(PSI.get_initial_time(simulation)) failed to execute ($status); see the simulation logs.")
    return PSI.get_decision_problem_results(PSI.SimulationResults(simulation), name)
end


# Builds and executes one `PSI.Simulation` of a one-interval `DecisionModel` over `steps`.
function _replication_simulation(
        sys::PSY.System, steps; optimizer = _DEFAULT_OPTIMIZER, parts = REPLICATION_PARTS,
        folder::AbstractString = mktempdir(), cache_size_mib = nothing,
    )
    (; simulation, model, skipped_constraints) =
        _build_range_simulation(sys, steps; optimizer = optimizer, parts = parts, folder = folder)
    results = try
        _execute_range_simulation(simulation; cache_size_mib = cache_size_mib)
    catch
        _log_skipped_constraints(skipped_constraints)
        rethrow()
    end
    return (; simulation, model, results, skipped_constraints)
end


# One range per chunk of `steps`: a chunk starts at the first step, at every 04:05 trading-day
# start and, with a `Dates.Period` `chunk`, every `chunk` after its own start.
function _range_chunks(steps::StepRange{DateTime}, chunk::Union{Symbol, Dates.Period})
    _check_chunk(chunk)
    starts = DateTime[]
    for t in steps
        starts_trading_day = Time(t) == Time(4, 5)
        periodic = chunk isa Dates.Period && !isempty(starts) && t - last(starts) >= chunk
        (isempty(starts) || starts_trading_day || periodic) && push!(starts, t)
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


# One chunk of `replicate_range`: system, simulation, execution, comparison and violations. Only
# the tables and the results reopened from `folder` are returned, so the system is collectable.
function _replicate_chunk(
        db, steps, k::Integer; intervention::Integer, optimizer, parts, interval_flow_limits::Bool, folder::AbstractString,
        time_series_in_memory::Bool, time_series_directory, cache_size_mib,
    )
    t0 = time()
    ts_directory = time_series_in_memory ? nothing : something(time_series_directory, joinpath(folder, "time_series"))
    time_series_in_memory || mkpath(ts_directory)
    sys = replication_system(
        db, first(steps):DISPATCH_INTERVAL:(last(steps) + _REPLICATION_HORIZON);
        intervention = intervention, interval_flow_limits = interval_flow_limits,
        time_series_in_memory = time_series_in_memory, time_series_directory = ts_directory,
    )
    system_build_s = time() - t0
    t1 = time()
    (; simulation, skipped_constraints) = _build_range_simulation(
        sys, steps; optimizer = optimizer, parts = parts, folder = folder,
    )
    simulation_build_s = time() - t1
    t2 = time()
    live = try
        _execute_range_simulation(simulation; cache_size_mib = cache_size_mib)
    catch
        _log_skipped_constraints(skipped_constraints)
        rethrow()
    end
    execute_s = time() - t2
    t3 = time()
    solved = _solved_tables(live, sys, parts)
    _check_prices_finite(solved.prices)
    comparison = _compare_to_published(read_published_interval(db, steps; intervention = intervention), solved, steps)
    violations = _constraint_violations(live, sys)
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
        constraint_violations = violations, ramp_violations = _ramp_violations(violations), solver_stats,
    )
end


"""
    replicate_range(db, start, stop; intervention = 0, optimizer = _DEFAULT_OPTIMIZER, parts = REPLICATION_PARTS,
        chunk = :trading_day, interval_flow_limits = false, output_dir = nothing, time_series_in_memory = true,
        time_series_directory = nothing, cache_size_mib = nothing) -> NamedTuple

Replays the historical NEM dispatch intervals `start:5 minutes:stop` and compares each with AEMO's
published outcome. Each chunk of the range is one `PowerSimulations.Simulation`: a one-interval
[`replication_template`](@ref) model is built once on a [`replication_system`](@ref) over the chunk
and stepped through its intervals, its parameters updating at each step, and every step starts from
the interval's published `INITIALMW`. A chunk starts at `start`, at every 04:05 trading-day start and,
with a `Dates.Period` `chunk`, every `chunk` after its own start. Each chunk
leaves out the generic constraints invoked at none of its intervals, prices every violation at each
interval's own Market Price Cap, and checks before its build
that its intervals share the same price-tied band pairs
([`check_tie_break_pairs`](@ref)) and a feasible dispatch envelope ([`check_dispatch_envelope`](@ref)).

# Arguments
- `db`: an `AEMDB` connection whose cache holds the tables of `ConstrainedNetworkConfiguration` plus
  `DISPATCHINTERCONNECTORRES`, from `start` to `stop + 10 minutes`.
- `start`, `stop`: `SETTLEMENTDATE`s a whole number of 5-minute intervals apart; `start == stop`
  replays one interval.
- `intervention`: 0 for the pricing run, 1 for the physical run.
- `optimizer`: the JuMP optimizer, e.g. `optimizer_with_attributes(HiGHS.Optimizer, ...)`. Defaults
  to HiGHS with `mip_rel_gap = 0` and `mip_abs_gap = 1e-10`, since the interconnector loss encoding is a MILP.
- `parts`: the [`REPLICATION_PARTS`](@ref) to model; default all.
- `chunk`: `:trading_day` or a `Dates.Period` that is a positive multiple of 5 minutes.
- `interval_flow_limits`: as in [`replication_system`](@ref); default `false`.
- `output_dir`: a directory for the chunk folders `chunk_<k>`; `nothing` uses a fresh `mktempdir()` per chunk.
- `time_series_in_memory`, `time_series_directory`: passed to [`replication_system`](@ref);
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
    _check_replication_parts(parts)
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
