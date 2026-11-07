"""
    bid_value(component, bid, field::Symbol, start_time, len) -> Union{Nothing, Any}

The value of one field of `bid`, the [`NEMEnergyBid`](@ref) or [`NEMFCASBid`](@ref) of `component`,
over `len` steps from `start_time`. A static field is returned as stored; a field held as a time
series is read over the window and converted to the static type: a `NTuple{4}` becomes a
[`FastStartProfile`](@ref) or [`FCASTrapeziumPoints`](@ref), and a `0`/`1` series a `Bool`.

# Arguments
- `component`: the device holding the bid.
- `bid`: the bid.
- `field`: the field name, such as `:max_avail` or `:fast_start_profile`.
- `start_time`: the first timestamp of the window.
- `len`: the number of steps.

# Returns
`nothing` for a field that is not set, the static value, or the window's values in the static type.
"""
function bid_value(component, bid, field::Symbol, start_time, len::Integer)
    value = getfield(bid, field)
    value isa IS.TimeSeriesKey || return value
    raw = IS.get_time_series_values(component, value; start_time, len)
    field === :normal_status && return raw .!= 0
    field === :fast_start_profile && return FastStartProfile[FastStartProfile(t) for t in raw]
    field === :trapezium && return FCASTrapeziumPoints[FCASTrapeziumPoints(t) for t in raw]
    return raw
end
