"""
    _replay_interval_stamps(sys::PSY.System) -> Vector{DateTime}

The first stamp of each replay interval of `sys`, five minutes apart. The series of a system built by
[`nem_system`](@ref) hold one point per stamp of its date range, and the build drops the final stamp,
so the replay intervals are all but the last two stamps of the date range.

# Arguments
- `sys`: the system whose `SingleTimeSeries` define the intervals.

# Returns
A `Vector{DateTime}` of the replay interval stamps, empty for a series of one point.
"""
function _replay_interval_stamps(sys::PSY.System)
    initial, n = PSY.check_time_series_consistency(sys, PSY.SingleTimeSeries)
    return collect(initial .+ (0:(n - 2)) .* Minute(5))
end
