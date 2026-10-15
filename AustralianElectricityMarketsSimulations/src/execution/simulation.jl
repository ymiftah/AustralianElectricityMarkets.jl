"Families of [`REPLICATION_PARTS`](@ref) that [`replicate_range`](@ref) can solve recurrently."
const _RECURRENT_PARTS = (:batteries, :fcas, :losses, :tie_breaks, :generic_constraints)


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


# Builds and executes one `PSI.Simulation` of a one-interval `DecisionModel` over `steps`.
function _replication_simulation(
        sys::PSY.System, steps; optimizer = _DEFAULT_OPTIMIZER, parts = _RECURRENT_PARTS, name = "dispatch",
    )
    unsupported = setdiff(parts, _RECURRENT_PARTS)
    isempty(unsupported) || throw(
        ArgumentError(
            "replicate_range: parts $(Tuple(unsupported)) cannot be solved recurrently yet; choose from $_RECURRENT_PARTS.",
        ),
    )
    _check_single_market_price_cap(steps)
    :tie_breaks in parts && check_tie_break_pairs(sys, steps)
    template_skipped = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int}[]
    template = replication_template(
        sys; skipped = template_skipped, parts = parts,
        exclude_constraints = _never_invoked_constraints(sys, steps),
    )
    skipped_constraints = _skipped_constraints_table(sys, template_skipped)
    check_dispatch_envelope(sys, template, first(steps), length(steps))
    model = _replication_decision_model(template, sys, first(steps); optimizer = optimizer, name = name, parts = parts)
    models = PSI.SimulationModels(; decision_models = [model])
    sequence = PSI.SimulationSequence(; models = models, ini_cond_chronology = PSI.InterProblemChronology())
    folder = mktempdir()
    simulation = PSI.Simulation(;
        name = "replicate_range", steps = length(steps), models = models,
        sequence = sequence, simulation_folder = folder, initial_time = first(steps),
    )
    build_status = PSI.build!(simulation; store_systems_in_results = false)
    build_status == PSI.SimulationBuildStatus.BUILT || begin
        _log_skipped_constraints(skipped_constraints)
        error("Range from $(first(steps)) failed to build ($build_status); see the logs in $folder.")
    end
    run_status = PSI.execute!(simulation)
    run_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED || begin
        _log_skipped_constraints(skipped_constraints)
        error("Range from $(first(steps)) failed to execute: $run_status; see the logs in $folder.")
    end
    results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), name)
    return (; simulation, model, results, skipped_constraints)
end


# `_compare_to_published` per step, stacked; `prices`, `dispatch` and `interconnectors` gain a
# leading `SETTLEMENTDATE` column (`fcas_prices` has one).
function _compare_range_to_published(db, sys::PSY.System, frames, steps, intervention::Integer)
    tables = (prices = DataFrame[], dispatch = DataFrame[], interconnectors = DataFrame[], fcas_prices = DataFrame[])
    for t in steps
        c = _compare_to_published(
            read_published_interval(db, t; intervention = intervention), _solved_interval(frames, sys, t),
        )
        for table in (:prices, :dispatch, :interconnectors)
            push!(tables[table], insertcols!(c[table], 1, :SETTLEMENTDATE => t))
        end
        push!(tables.fcas_prices, c.fcas_prices)
    end
    return map(dfs -> reduce(vcat, dfs), tables)
end


"""
    replicate_range(db, start, stop; intervention = 0, optimizer = _DEFAULT_OPTIMIZER, parts = (:batteries, :fcas, :losses, :tie_breaks, :generic_constraints)) -> NamedTuple

Replays the dispatch intervals `start:5 minutes:stop` as one `PowerSimulations.Simulation` of
a one-interval [`replication_template`](@ref) model built once on a [`replication_system`](@ref) over
the range, and compares each interval with AEMO's published outcome.

`:batteries`, `:fcas` (an [`FCASMarket`](@ref) per `FCASService`), `:losses` (interconnectors under
[`NEMInterconnectorLoss`](@ref), MNSP offers included), `:tie_breaks` (energy tie-breaks, which
require the same price-tied band pairs at every interval, [`check_tie_break_pairs`](@ref), so a range
must not cross the start of a trading day) and `:generic_constraints` are recurrently solvable. Without `:fcas`, each generic constraint with an FCAS
term whose service has available devices is dropped whole, as is each constraint invoked at no
interval. A constraint invoked at some intervals is modeled at every interval and relaxed at no cost
where it is not invoked.

# Arguments
- `db`: an `AEMDB` connection whose cache holds data from `start` to `stop + 5 minutes`.
- `start`, `stop`: `DateTime`s a whole number of 5-minute intervals apart, within one Market Price Cap year.
- `intervention`: 0 for the pricing run, 1 for the physical run.
- `optimizer`: the JuMP optimizer, e.g. `optimizer_with_attributes(HiGHS.Optimizer, ...)`.
- `parts`: the recurrently solvable [`REPLICATION_PARTS`](@ref), a subset of `(:batteries, :fcas, :losses, :tie_breaks, :generic_constraints)`.

# Returns
A `NamedTuple` of `simulation`, `results` (`SimulationProblemResults`), `skipped_constraints` (as
[`replicate_interval`](@ref)'s, with `reason = :never_invoked` for a constraint invoked at no
interval) and `comparison`
([`replicate_interval`](@ref)'s tables stacked over intervals with a `SETTLEMENTDATE` column).
The FCAS `ROP_solved` is `missing` unless `parts` includes `:fcas` and `:generic_constraints`, and
`MWFLOW_solved`/`MWLOSSES_solved` are `missing` unless `parts` includes `:losses`. `ramp_violations`
and `constraint_violations` are [`replicate_interval`](@ref)'s slack tables over every interval
of the range, keyed by `DateTime`. Throws if the simulation does not build or execute.
"""
function replicate_range(
        db, start::DateTime, stop::DateTime; intervention::Integer = 0,
        optimizer = _DEFAULT_OPTIMIZER, parts = _RECURRENT_PARTS,
    )
    steps = _range_steps(start, stop)
    sys = replication_system(db, start:DISPATCH_INTERVAL:(stop + DISPATCH_INTERVAL); intervention = intervention)
    (; simulation, results, skipped_constraints) = _replication_simulation(sys, steps; optimizer = optimizer, parts = parts)
    frames = _solved_frames(results, sys; losses = :losses in parts)
    _check_prices_finite(frames.balance_duals)
    comparison = _compare_range_to_published(db, sys, frames, steps, intervention)
    violations = _constraint_violations(results, sys)
    return (;
        simulation, results, skipped_constraints, comparison,
        ramp_violations = _ramp_violations(violations), constraint_violations = violations,
    )
end
