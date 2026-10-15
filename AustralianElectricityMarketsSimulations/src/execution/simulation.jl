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


# Penalty multipliers and every CVP cost are fixed at build, so the range must sit under one Market Price Cap.
function _check_single_market_price_cap(steps)
    _financial_year_mpc(first(steps)) == _financial_year_mpc(last(steps)) || throw(
        ArgumentError(
            "replicate_range: the intervals ending $(first(steps)) and $(last(steps)) fall under different Market Price Caps; split the range so that 00:05 on 1 July starts a range.",
        ),
    )
    return
end


# Available `GenericConstraint`s invoked at none of `steps`, each mapped to `:never_invoked`.
function _never_invoked_constraints(sys::PSY.System, steps)
    reasons = Dict{String, Symbol}()
    for gc in PSY.get_components(GenericConstraint, sys)
        PSY.get_available(gc) || continue
        invoked = PSY.get_time_series_values(PSY.SingleTimeSeries, gc, "invoked"; start_time = first(steps), len = length(steps))
        all(iszero, invoked) && (reasons[PSY.get_name(gc)] = :never_invoked)
    end
    return reasons
end


# Template, pre-flight checks and a built `PSI.Simulation` of a one-interval `DecisionModel` over `steps`.
function _build_range_simulation(
        sys::PSY.System, steps; optimizer = _DEFAULT_OPTIMIZER, parts = REPLICATION_PARTS, name = "dispatch",
        folder = mktempdir(),
    )
    _check_single_market_price_cap(steps)
    :tie_breaks in parts && check_tie_break_pairs(sys, steps)
    template_skipped = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int}[]
    template = replication_template(
        sys; skipped = template_skipped, parts = parts,
        exclude_constraints = _never_invoked_constraints(sys, steps),
    )
    check_fcas_services(sys, template)
    skipped_constraints = _skipped_constraints_table(sys, template_skipped)
    check_dispatch_envelope(sys, template, first(steps), length(steps))
    model = _replication_decision_model(template, sys, first(steps); optimizer = optimizer, name = name, parts = parts)
    models = PSI.SimulationModels(; decision_models = [model])
    sequence = PSI.SimulationSequence(; models = models, ini_cond_chronology = PSI.InterProblemChronology())
    simulation = PSI.Simulation(;
        name = "replicate_range", steps = length(steps), models = models,
        sequence = sequence, simulation_folder = folder, initial_time = first(steps),
    )
    build_status = PSI.build!(simulation; store_systems_in_results = false)
    build_status == PSI.SimulationBuildStatus.BUILT || begin
        _log_skipped_constraints(skipped_constraints)
        error("Range from $(first(steps)) failed to build ($build_status); see the logs in $folder.")
    end
    return (; simulation, model, skipped_constraints)
end


# Executes a built simulation and returns the results of its decision problem `name`.
function _execute_range_simulation(simulation::PSI.Simulation; name = "dispatch", cache_size_mib = nothing)
    kwargs = isnothing(cache_size_mib) ? (;) : (; cache_size_mib = cache_size_mib)
    run_status = PSI.execute!(simulation; kwargs...)
    run_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED ||
        error("Range failed to execute: $run_status; see the simulation logs.")
    return PSI.get_decision_problem_results(PSI.SimulationResults(simulation), name)
end


# Builds and executes one `PSI.Simulation` of a one-interval `DecisionModel` over `steps`.
function _replication_simulation(
        sys::PSY.System, steps; optimizer = _DEFAULT_OPTIMIZER, parts = REPLICATION_PARTS, name = "dispatch",
    )
    (; simulation, model, skipped_constraints) =
        _build_range_simulation(sys, steps; optimizer = optimizer, parts = parts, name = name)
    results = try
        _execute_range_simulation(simulation; name = name)
    catch
        _log_skipped_constraints(skipped_constraints)
        rethrow()
    end
    return (; simulation, model, results, skipped_constraints)
end


# `_compare_to_published` per step, stacked; `prices`, `dispatch` and `interconnectors` gain a
# leading `SETTLEMENTDATE` column (`fcas_prices` has one). The published outcomes are read once.
function _compare_range_to_published(db, sys::PSY.System, frames, steps, intervention::Integer)
    published = read_published_interval(db, steps; intervention = intervention)
    by_interval = map(df -> _by_interval(df, :SETTLEMENTDATE), published)
    tables = (prices = DataFrame[], dispatch = DataFrame[], interconnectors = DataFrame[], fcas_prices = DataFrame[])
    for t in steps
        rows_at(table) = get(by_interval[table], t, view(published[table], 1:0, :))
        c = _compare_to_published(
            (;
                prices = select(rows_at(:prices), Not(:SETTLEMENTDATE)),
                dispatch = select(rows_at(:dispatch), Not(:SETTLEMENTDATE)),
                interconnectors = select(rows_at(:interconnectors), Not(:SETTLEMENTDATE)),
                fcas_prices = rows_at(:fcas_prices),
            ),
            _solved_interval(frames, sys, t),
        )
        for table in (:prices, :dispatch, :interconnectors)
            push!(tables[table], insertcols!(c[table], 1, :SETTLEMENTDATE => t))
        end
        push!(tables.fcas_prices, c.fcas_prices)
    end
    return map(dfs -> reduce(vcat, dfs), tables)
end


# Chunk starts that break `steps` where a trading day (04:05) or the financial year (00:05 on 1 July)
# begins, and every `chunk` after a range's own start. Returns one range per chunk.
function _range_chunks(steps::StepRange{DateTime}, chunk::Union{Symbol, Dates.Period})
    _check_chunk(chunk)
    starts = DateTime[]
    chunk_start = first(steps)
    for t in steps
        starts_trading_day = Time(t) == Time(4, 5)
        starts_financial_year = month(t) == 7 && day(t) == 1 && Time(t) == Time(0, 5)
        periodic = chunk isa Dates.Period && t - chunk_start >= chunk
        if t == first(steps) || starts_trading_day || starts_financial_year || periodic
            push!(starts, t)
            chunk_start = t
        end
    end
    ends = [starts[2:end] .- DISPATCH_INTERVAL; last(steps)]
    return [a:DISPATCH_INTERVAL:b for (a, b) in zip(starts, ends)]
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


# Whether a simulation store keeps the replication model's own time-series parameters.
const _STORE_REPLICATION_PARAMETERS = Ref(true)

const _REPLICATION_PARAMETER_TYPES = Union{
    NEMConstraintRHSParameter, FCASOfferLimitParameter, FCASBandWidthParameter,
    FCASUpperSlopeParameter, FCASLowerSlopeParameter, FCASRampingLimitParameter,
    TieBreakScaleParameter, LossDemandCoefficientParameter, MNSPBandWidthParameter,
    MNSPMaxAvailParameter, RampUpRateTimeSeriesParameter, RampDownRateTimeSeriesParameter,
    InitialPowerTimeSeriesParameter,
}
PSI.should_write_resulting_value(::Type{<:_REPLICATION_PARAMETER_TYPES}) = _STORE_REPLICATION_PARAMETERS[]


# One chunk of `replicate_range`: system, simulation, execution, comparison and violations. Everything
# but the reopened results and the tables is local, so the system is collectable on return.
function _replicate_chunk(
        db, steps, k::Integer; intervention::Integer, optimizer, parts, folder::String,
        time_series_in_memory::Bool, time_series_directory, cache_size_mib,
    )
    t0 = time()
    sys = replication_system(
        db, first(steps):DISPATCH_INTERVAL:(last(steps) + DISPATCH_INTERVAL);
        intervention = intervention, time_series_in_memory = time_series_in_memory,
        time_series_directory = time_series_directory,
    )
    system_build_s = time() - t0
    t1 = time()
    (; simulation, skipped_constraints) = _build_range_simulation(
        sys, steps; optimizer = optimizer, parts = parts, folder = folder,
    )
    simulation_build_s = time() - t1
    t2 = time()
    live = _execute_range_simulation(simulation; cache_size_mib = cache_size_mib)
    execute_s = time() - t2
    t3 = time()
    frames = _solved_frames(live, sys; losses = :losses in parts)
    _check_prices_finite(frames.balance_duals)
    comparison = _compare_range_to_published(db, sys, frames, steps, intervention)
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
        system_build_s, simulation_build_s, execute_s, compare_s, results = reopened,
        comparison, skipped_constraints, constraint_violations = violations,
        ramp_violations = _ramp_violations(violations), solver_stats,
    )
end


"""
    replicate_range(db, start, stop; intervention = 0, optimizer = _DEFAULT_OPTIMIZER, parts = REPLICATION_PARTS,
        chunk = :trading_day, output_dir = nothing, time_series_in_memory = true,
        time_series_directory = nothing, cache_size_mib = nothing, store_parameters = true) -> NamedTuple

Replays the dispatch intervals `start:5 minutes:stop` by solving them as `PowerSimulations.Simulation`s,
one per chunk, and compares each interval with AEMO's published outcome. Each chunk is built on a
[`replication_system`](@ref) over its own intervals and solved by a one-interval
[`replication_template`](@ref) model that is built once per chunk and whose parameters update at each step.
The full template is modeled by default; `parts` leaves families out for diagnosis. Each generic
constraint invoked at no interval is left out, and a constraint invoked at some intervals is modeled
at every interval and relaxed at no cost where it is not invoked.

A chunk always starts at `start`, at every 04:05 interval (the start of a trading day, where
[`check_tie_break_pairs`](@ref) requires the same tie pairs) and at 00:05 on 1 July (the start of a
Market Price Cap year). With a `Dates.Period` `chunk`, a chunk also starts every `chunk` after its own
start. Each chunk's pre-flight checks run before its build; a failing chunk logs the folders of the
chunks already solved and rethrows. Once a chunk is solved its system and simulation are released, and
its results are reopened from its folder.

# Arguments
- `db`: an `AEMDB` connection whose cache holds data from `start` to `stop + 5 minutes`.
- `start`, `stop`: `DateTime`s a whole number of 5-minute intervals apart, within one Market Price Cap year.
- `intervention`: 0 for the pricing run, 1 for the physical run.
- `optimizer`: the JuMP optimizer, e.g. `optimizer_with_attributes(HiGHS.Optimizer, ...)`.
- `parts`: the [`REPLICATION_PARTS`](@ref) to model; default all.
- `chunk`: `:trading_day` or a `Dates.Period` that is a positive multiple of 5 minutes.
- `output_dir`: a directory on disk for the chunk folders `chunk_<k>`; `nothing` uses a fresh `mktempdir()` per chunk.
- `time_series_in_memory`, `time_series_directory`: passed to [`replication_system`](@ref).
- `cache_size_mib`: the simulation store's write cache in MiB; `nothing` keeps PowerSimulations' default.
- `store_parameters`: whether the simulation stores keep the replication model's own time-series
  parameters (the `NEMConstraintRHSParameter`, FCAS, tie-break, loss, MNSP and ramp parameters).

# Returns
A `NamedTuple` of
- `chunks`: a `DataFrame` with one row per chunk: `chunk`, `start`, `stop`, `n_steps`, `folder`,
  `system_build_s`, `simulation_build_s`, `execute_s` and `compare_s` (seconds).
- `results`: a `Vector` of the `SimulationProblemResults` of each chunk, reopened from its folder.
- `skipped_constraints`: as [`replicate_interval`](@ref)'s, stacked over chunks with a leading `chunk` column;
  `reason = :never_invoked` marks a constraint invoked at no interval.
- `comparison`: [`replicate_interval`](@ref)'s tables stacked over intervals with a `SETTLEMENTDATE` column.
- `ramp_violations`, `constraint_violations`: [`replicate_interval`](@ref)'s slack tables over every interval.
- `solver_stats`: a `DataFrame` with one row per interval: `SETTLEMENTDATE`, `chunk`, `objective_value`,
  `solver_solve_time`, `timed_solve_time`, `timed_calculate_dual_variables` and `termination_status`.

The FCAS `ROP_solved` is `missing` unless `parts` includes `:fcas` and `:generic_constraints`, and
`MWFLOW_solved`/`MWLOSSES_solved` are `missing` unless `parts` includes `:losses`. Throws if a chunk
does not satisfy its pre-flight checks, build or execute.
"""
function replicate_range(
        db, start::DateTime, stop::DateTime; intervention::Integer = 0,
        optimizer = _DEFAULT_OPTIMIZER, parts = REPLICATION_PARTS, chunk = :trading_day,
        output_dir::Union{Nothing, AbstractString} = nothing, time_series_in_memory::Bool = true,
        time_series_directory::Union{Nothing, AbstractString} = nothing,
        cache_size_mib::Union{Nothing, Integer} = nothing, store_parameters::Bool = true,
    )
    steps = _range_steps(start, stop)
    chunks = _range_chunks(steps, chunk)
    previous = _STORE_REPLICATION_PARAMETERS[]
    _STORE_REPLICATION_PARAMETERS[] = store_parameters
    try
        folders = String[]
        meta = DataFrame[]
        outs = []
        for (k, s) in enumerate(chunks)
            folder = isnothing(output_dir) ? mktempdir() : mkpath(joinpath(output_dir, "chunk_$k"))
            push!(folders, folder)
            out = try
                _replicate_chunk(
                    db, s, k; intervention = intervention, optimizer = optimizer, parts = parts,
                    folder = folder, time_series_in_memory = time_series_in_memory,
                    time_series_directory = time_series_directory, cache_size_mib = cache_size_mib,
                )
            catch
                @error "replicate_range: chunk $k ($(first(s)) to $(last(s))) failed; solved chunk folders: $(folders[1:(end - 1)])"
                rethrow()
            end
            push!(outs, out)
            push!(
                meta, DataFrame(
                    chunk = [k], start = [first(s)], stop = [last(s)], n_steps = [length(s)], folder = [folder],
                    system_build_s = [out.system_build_s], simulation_build_s = [out.simulation_build_s],
                    execute_s = [out.execute_s], compare_s = [out.compare_s],
                ),
            )
            GC.gc()
        end
        vcat_field(field) = reduce(vcat, [getproperty(out, field) for out in outs])
        comparison = NamedTuple(
            name => reduce(vcat, [getproperty(out.comparison, name) for out in outs]) for name in keys(outs[1].comparison)
        )
        skipped = reduce(vcat, [insertcols(out.skipped_constraints, 1, :chunk => k) for (k, out) in enumerate(outs)])
        return (;
            chunks = reduce(vcat, meta),
            results = [out.results for out in outs],
            skipped_constraints = skipped,
            comparison,
            ramp_violations = vcat_field(:ramp_violations),
            constraint_violations = vcat_field(:constraint_violations),
            solver_stats = vcat_field(:solver_stats),
        )
    finally
        _STORE_REPLICATION_PARAMETERS[] = previous
    end
end
