"""
    check_replication_steps(sys, steps)

Verifies that `steps` is a non-empty range of five-minute intervals and that `sys` carries attached
forecast windows covering each of them.

# Arguments
- `sys`: the system the simulation runs on, prepared with `prepare_replay_forecasts!`.
- `steps`: the interval-ending timestamps the simulation solves.

# Returns
`nothing`. Throws an `ArgumentError` for an invalid range, for a system without forecasts, or for
steps the attached forecasts do not cover.
"""
function check_replication_steps(sys::PSY.System, steps::StepRange{DateTime})
    (!isempty(steps) && step(steps) == DISPATCH_INTERVAL) || throw(
        ArgumentError("check_replication_steps: steps must be a non-empty range of five-minute intervals."),
    )
    PSY.get_time_series_counts(sys).forecast_count > 0 || throw(
        ArgumentError("check_replication_steps: call prepare_replay_forecasts!(sys) before constructing a simulation."),
    )
    missing_steps = setdiff(steps, PSY.get_forecast_initial_times(sys))
    isempty(missing_steps) || throw(
        ArgumentError("check_replication_steps: attached forecasts do not cover $(first(missing_steps)); construct a system covering the requested range."),
    )
    return
end

"""
    never_invoked_constraints(sys, steps) -> Dict{String, Symbol}

Maps each available `GenericConstraint` of `sys` that is invoked in none of `steps` to `:never_invoked`,
the `exclude_constraints` reason of [`replication_template`](@ref).

# Arguments
- `sys`: the system prepared with `prepare_replay_forecasts!`, whose constraints carry an `"invoked"` series.
- `steps`: the interval-ending timestamps the simulation solves.

# Returns
A `Dict` from constraint name to `:never_invoked`; empty when every constraint is invoked in some interval.
"""
function never_invoked_constraints(sys::PSY.System, steps)
    reasons = Dict{String, Symbol}()
    for gc in PSY.get_components(PSY.get_available, GenericConstraint, sys)
        invoked = PSY.get_time_series_values(
            PSY.SingleTimeSeries, gc, "invoked"; start_time = first(steps), len = length(steps),
        )
        all(iszero, invoked) && (reasons[PSY.get_name(gc)] = :never_invoked)
    end
    return reasons
end
