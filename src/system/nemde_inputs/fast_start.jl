# The fast-start state of each unit whose energy offer carries a fast-start profile, read per interval.


# The energy bid of `device` whose profile is fast-start at some stamp, the generation side first; `nothing` without one.
# With a `cache` (a dictionary kept by a caller that reads every step), the bid is found once per device.
function _fast_start_bid(device, cache = nothing)
    isnothing(cache) && return _fast_start_bid_uncached(device)
    return get!(() -> _fast_start_bid_uncached(device), cache, (PSY.get_name(device), :bid))
end

function _fast_start_bid_uncached(device)
    cost = _nem_offer_cost(device)
    isnothing(cost) && return nothing
    for side in (OfferSide.GEN, OfferSide.LOAD)
        bid = _energy_bid(cost, side)
        (isnothing(bid) || isnothing(bid.fast_start_profile)) && continue
        _any_fast_start(device, bid.fast_start_profile) && return bid
    end
    return nothing
end

# Whether a profile held as a static value or a series key is fast-start at some stamp.
_any_fast_start(device, profile::FastStartProfile) = is_fast_start(profile)
function _any_fast_start(device, key::IS.StaticTimeSeriesKey)
    raw = IS.get_time_series_values(device, key)::Vector{NTuple{4, Float64}}
    return any(t -> is_fast_start(FastStartProfile(t)), raw)
end

# The `len` values of a window from `start_time`, sliced from a whole-series read `(timestamps, values)` kept in
# `cache` under `key`, so a caller reading every step reads each series from storage once. A window the read does not
# cover is read from storage, as `read_window()` does; with no cache, `read_window()` is the whole answer.
function _cached_window(read_full::Function, cache, key, start_time::DateTime, len::Integer, read_window::Function)
    isnothing(cache) && return read_window()
    stamps, values = get!(read_full, cache, key)
    i = searchsortedfirst(stamps, start_time)
    if i <= length(stamps) && stamps[i] == start_time && i + len - 1 <= length(values)
        return values[i:(i + len - 1)]
    end
    return read_window()
end

# Converts a whole-series read of the bid field `field` to the values `bid_value` gives for it.
_field_values(::Val{:fast_start_profile}, raw) = FastStartProfile[FastStartProfile(t) for t in raw]
_field_values(::Val{:minimum_load}, raw) = Vector{Float64}(raw)

# The window of the bid field `field` of `device`, as `bid_value`, read through `cache` when one is given.
function _bid_field_window(device, bid, field::Symbol, start_time::DateTime, len::Integer, cache)
    value = getproperty(bid, field)
    value isa IS.StaticTimeSeriesKey || return bid_value(device, bid, field, start_time, len)
    read_full() = (IS.get_time_series_timestamps(device, value), _field_values(Val(field), IS.get_time_series_values(device, value)))
    read_window() = bid_value(device, bid, field, start_time, len)
    return _cached_window(read_full, cache, (PSY.get_name(device), field), start_time, len, read_window)
end


"""
    has_fast_start_profile(device) -> Bool

Whether an energy bid of `device` carries a fast-start profile ([`is_fast_start`](@ref)) at some interval of the
run.
Such a device gets the series of [`NEM_FAST_START_SERIES`](@ref); whether it is fast-start at a given interval is
[`fast_start_unit_inputs`](@ref)'s `fast_start` field.

# Arguments
- `device`: the NEM device.

# Returns
`Bool`.
"""
has_fast_start_profile(device) = !isnothing(_fast_start_bid(device))


# The fast-start profile of `device` at each of `stamps`, `nothing` at every stamp without a profile bid.
function _fast_start_profile_window(device, stamps::AbstractVector{DateTime})
    bid = _fast_start_bid(device)
    isnothing(bid) && return fill(nothing, length(stamps))
    value = bid_value(device, bid, :fast_start_profile, first(stamps), length(stamps))
    return value isa AbstractVector ? value : fill(value, length(stamps))
end


"""
    FastStartUnitInputs

The fast-start inputs of one unit at one interval, from [`fast_start_unit_inputs`](@ref), in natural units.

# Fields
- `fast_start`: whether the offer's profile makes the unit fast-start in the interval ([`is_fast_start`](@ref)).
- `side`: the [`OfferSide`](@ref) of the energy bid carrying the profile; the profile applies to the target on
  that side's axis (consumption for a load).
- `start_mode`: the dispatch mode at the start of the interval, from 0 to 4.
- `time_in_mode`: the minutes in `start_mode` at the start of the interval, capped at the mode's length.
- `profile`: the offer's [`FastStartProfile`](@ref) at the interval, minutes.
- `minimum_load`: the offer's `MINIMUMLOAD` at the interval, MW, `0.0` where unpublished.
"""
struct FastStartUnitInputs
    fast_start::Bool
    side::OfferSide
    start_mode::Int
    time_in_mode::Float64
    profile::FastStartProfile
    minimum_load::Float64
end


"""
    fast_start_unit_inputs(device, start_time::DateTime, len::Integer) -> Vector{FastStartUnitInputs}

The fast-start inputs of `device` at each of the `len` intervals from `start_time`, read from the series that
[`nem_system`](@ref) writes ([`NEM_FAST_START_SERIES`](@ref)) and from the energy bid carrying the profile. With
the first run's energy target they are the arguments of [`fast_start_end_state`](@ref) and
[`fast_start_envelope`](@ref).

# Arguments
- `device`: a NEMDE unit with [`has_fast_start_profile`](@ref), of a System built by
  `nem_system(db, NEMDEConfiguration(); date_range)`.
- `start_time`: the first timestamp of the window.
- `len`: the number of intervals.

# Returns
A `Vector{FastStartUnitInputs}` of length `len`. Throws an `ArgumentError` when `device` has no fast-start profile
or its fast-start series were not written.
"""
function fast_start_unit_inputs(device, start_time::DateTime, len::Integer; cache = nothing)
    name = PSY.get_name(device)
    bid = _fast_start_bid(device, cache)
    isnothing(bid) && throw(ArgumentError("\"$name\" has no energy bid with a fast-start profile."))
    PSY.has_time_series(device, PSY.SingleTimeSeries, NEM_FAST_START_SERIES.start_mode) || throw(
        ArgumentError("\"$name\" has no fast-start series; build the System with nem_system."),
    )
    function window(series)
        read_full() = (
            PSY.get_time_series_timestamps(PSY.SingleTimeSeries, device, series),
            PSY.get_time_series_values(PSY.SingleTimeSeries, device, series; ignore_scaling_factors = true),
        )
        read_window() = PSY.get_time_series_values(
            PSY.SingleTimeSeries, device, series; start_time, len, ignore_scaling_factors = true,
        )
        return _cached_window(read_full, cache, (name, series), start_time, len, read_window)
    end
    flag, mode, time = window.((NEM_FAST_START_SERIES.flag, NEM_FAST_START_SERIES.start_mode, NEM_FAST_START_SERIES.time_in_mode))
    profiles = _bid_field_window(device, bid, :fast_start_profile, start_time, len, cache)
    loads = isnothing(bid.minimum_load) ? 0.0 : _bid_field_window(device, bid, :minimum_load, start_time, len, cache)
    side = _energy_offer_side(bid.direction)
    return [
        FastStartUnitInputs(
            !iszero(flag[i]), side, Int(mode[i]), time[i], profiles isa AbstractVector ? profiles[i] : profiles,
            loads isa AbstractVector ? loads[i] : Float64(loads),
        ) for i in 1:len
    ]
end


"""
    _set_fast_start_inputs!(sys::PSY.System, grid = _nemde_grid(sys)) -> Nothing

Adds, for each NEM dispatch device of `sys` with [`has_fast_start_profile`](@ref) and a time-series observed
starting output, the series named by [`NEM_FAST_START_SERIES`](@ref) on `grid`: the
fast-start flag, the starting mode and the capped time in mode of [`observed_unit_states`](@ref). A repeat call
replaces the series.

# Arguments
- `sys`: the system whose observed state and bids [`nem_system`](@ref) attached.
- `grid`: the timestamps the single time series of `sys` share; read from `sys` by default.

# Returns
`nothing`.
"""
function _set_fast_start_inputs!(sys::PSY.System, grid = _nemde_grid(sys))
    _foreach_nem_dispatch_device(sys) do device
        has_fast_start_profile(device) || return
        observed = get_observed_state(device)
        observed.initial_mw isa IS.StaticTimeSeriesKey || return
        states = observed_unit_states(device, grid)
        flags = [is_fast_start(p) ? 1.0 : 0.0 for p in _fast_start_profile_window(device, grid)]
        series = (
            NEM_FAST_START_SERIES.flag => flags,
            NEM_FAST_START_SERIES.start_mode => [Float64(s.dispatch_mode) for s in states],
            NEM_FAST_START_SERIES.time_in_mode => [s.time_in_mode for s in states],
        )
        for (series_name, values) in series
            replace_single_series!(sys, device, single_series(series_name, first(grid), values, step(grid)))
        end
        return
    end
    return
end
