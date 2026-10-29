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
        ArgumentError("replication_simulation: steps must be a non-empty range of five-minute intervals."),
    )
    PSY.get_time_series_counts(sys).forecast_count > 0 || throw(
        ArgumentError("replication_simulation: call prepare_replay_forecasts!(sys) before constructing a simulation."),
    )
    missing_steps = setdiff(steps, PSY.get_forecast_initial_times(sys))
    isempty(missing_steps) || throw(
        ArgumentError("replication_simulation: attached forecasts do not cover $(first(missing_steps)); construct a system covering the requested range."),
    )
    return
end
