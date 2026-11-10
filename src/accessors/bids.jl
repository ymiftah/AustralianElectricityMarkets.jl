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
    return bid_value(component, bid, Val(field), start_time, len)
end

# The window of a series in its element type `T`; a static value is returned as stored.
function _bid_window_values(::Type{T}, component, key::IS.TimeSeriesKey, start_time, len::Integer) where {T}
    return IS.get_time_series_values(component, key; start_time, len)::Vector{T}
end

# Methods by field name, so each field's read is typed; the `Symbol` method above forwards here.
function bid_value(component, bid, ::Val{F}, start_time, len::Integer) where {F}
    value = getproperty(bid, F)
    value isa IS.StaticTimeSeriesKey || return value
    return _bid_window_values(Float64, component, value, start_time, len)
end

function bid_value(component, bid, ::Val{:offer_curves}, start_time, len::Integer)
    value = bid.offer_curves
    value isa IS.StaticTimeSeriesKey || return value
    return _bid_window_values(PiecewiseStepData, component, value, start_time, len)
end

function bid_value(component, bid, ::Val{:normal_status}, start_time, len::Integer)
    value = bid.normal_status
    value isa IS.StaticTimeSeriesKey || return value
    return _bid_window_values(Float64, component, value, start_time, len) .!= 0
end

function bid_value(component, bid, ::Val{:fast_start_profile}, start_time, len::Integer)
    value = bid.fast_start_profile
    value isa IS.StaticTimeSeriesKey || return value
    raw = _bid_window_values(NTuple{4, Float64}, component, value, start_time, len)
    return FastStartProfile[FastStartProfile(t) for t in raw]
end

function bid_value(component, bid, ::Val{:trapezium}, start_time, len::Integer)
    value = bid.trapezium
    value isa IS.StaticTimeSeriesKey || return value
    raw = _bid_window_values(NTuple{4, Float64}, component, value, start_time, len)
    return FCASTrapeziumPoints[FCASTrapeziumPoints(t) for t in raw]
end
