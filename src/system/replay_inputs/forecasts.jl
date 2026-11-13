"""
    _set_replay_forecasts!(sys::PSY.System) -> Nothing

Transforms the single time series of `sys` into five-minute forecast windows of one interval each, so the
replay reads one interval per step. Called last by `_set_replay_inputs!`: a series added after it is not
transformed, and adding one fails.

# Arguments
- `sys`: the system built by [`nem_system`](@ref), whose series hold one point per stamp of its date range
  but the last two.

# Returns
`nothing`.
"""
function _set_replay_forecasts!(sys::PSY.System)
    PSY.transform_single_time_series!(sys, DISPATCH_INTERVAL, DISPATCH_INTERVAL)
    return
end


"""
    replay_intervals(sys::PSY.System) -> Vector{DateTime}

The interval-ending stamps of the replay intervals of `sys`: the initial times of its forecast windows
without the last one, five minutes apart.

# Arguments
- `sys`: the system built by [`nem_system`](@ref).

# Returns
A `Vector{DateTime}` of the replay intervals. Throws `ArgumentError` when `sys` has no forecasts.
"""
function replay_intervals(sys::PSY.System)
    PSY.get_time_series_counts(sys).forecast_count > 0 || throw(
        ArgumentError("replay_intervals: the system has no forecasts; build it with nem_system(db, NEMDEConfiguration(); date_range)."),
    )
    return collect(PSY.get_forecast_initial_times(sys)[1:(end - 1)])
end
