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


# The NEM devices of `sys` that can carry offers.
_bidding_devices(sys::PSY.System) = Iterators.flatten(
    (PSY.get_components(T, sys) for T in (PSY.Generator, PSY.ControllableLoad, PSY.Storage)),
)

# The timestamps, resolution and values of a bid field's time series on `device`.
function _bid_series(device, key::IS.TimeSeriesKey, ::Symbol)
    ts::PSY.SingleTimeSeries = IS.get_time_series(device, key)
    array = PSY.get_time_series_array(device, ts)
    return (;
        timestamps = PSY.TimeSeries.timestamp(array), resolution = IS.get_resolution(ts),
        values = collect(values(array)),
    )
end

# A static bid field has no series to derive the offers from.
function _bid_series(device, value, field::Symbol)
    throw(
        ArgumentError(
            "\"$(PSY.get_name(device))\" has a static `$(field)` field; the replay inputs need series-backed " *
                "bid inputs, as set_market_bids! writes them.",
        ),
    )
end

# The values of a telemetry key over the grid of `like`: a static value is repeated.
function _grid_values(device, key, like)
    key isa IS.StaticTimeSeriesKey || return fill(Float64(key), length(like.values))
    return _bid_series(device, key, :availability).values
end

# The values of `key` on the timestamps of `like`: a static value is repeated, and a stamp the
# series does not cover is `NaN`, so a bid on another window limits nothing.
function _aligned_values(device, key, like)
    key isa IS.StaticTimeSeriesKey || return fill(Float64(key), length(like.values))
    series = _bid_series(device, key, :availability)
    values = fill(NaN, length(like.values))
    index = Dict(t => i for (i, t) in enumerate(like.timestamps))
    for (i, t) in enumerate(series.timestamps)
        j = get(index, t, nothing)
        isnothing(j) || (values[j] = series.values[i])
    end
    return values
end

# The energy bid of `cost` on `side`, or `nothing`.
function _energy_bid(cost, side::OfferSide)
    i = findfirst(b -> _energy_offer_side(b.direction) == side, get_energy_bids(cost))
    return isnothing(i) ? nothing : get_energy_bids(cost)[i]
end

# The loss factor that refers `side`'s prices to the reference node, from the unit's registration.
function _loss_factor(device, side::OfferSide)
    registration = get_registration(device)
    return side == OfferSide.LOAD ? registration.load_loss_factor : registration.gen_loss_factor
end


# The directions of an MNSP link, as `set_mnsp_offers!` names them.
const _MNSP_DIRECTIONS = ("forward", "reverse")


# The `NEMMNSPBid` of `device` for `direction` (`"forward"` or `"reverse"`), or `nothing` when it has none.
function _mnsp_bid(device::PSY.AreaInterchange, direction::AbstractString)
    dir = direction == "forward" ? MNSPDirection.FORWARD : MNSPDirection.REVERSE
    bids = [b for b in (PSY.get_supplemental_attributes(NEMMNSPBid, device)::Vector{NEMMNSPBid}) if b.direction == dir]
    isempty(bids) && return nothing
    length(bids) == 1 || throw(
        ArgumentError("AreaInterchange \"$(PSY.get_name(device))\" carries $(length(bids)) NEMMNSPBid for its $direction link; it requires one."),
    )
    return only(bids)
end
