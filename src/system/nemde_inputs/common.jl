"""
    _dispatch_interval_stamps(sys::PSY.System) -> Vector{DateTime}

The first stamp of each dispatch interval of `sys`, five minutes apart. The series of a system built by
[`nem_system`](@ref) hold one point per stamp of its date range, and the build drops the final stamp,
so the dispatch intervals are all but the last two stamps of the date range.

# Arguments
- `sys`: the system whose `SingleTimeSeries` define the intervals.

# Returns
A `Vector{DateTime}` of the dispatch interval stamps, empty for a series of one point.
"""
function _dispatch_interval_stamps(sys::PSY.System)
    initial, n = PSY.check_time_series_consistency(sys, PSY.SingleTimeSeries)
    return collect(initial .+ (0:(n - 2)) .* DISPATCH_INTERVAL)
end


# Refuses single time series that are not at the dispatch interval, which every NEMDE input is derived on.
function _check_nemde_resolution(sys::PSY.System)
    resolutions = PSY.get_time_series_resolutions(sys; time_series_type = PSY.SingleTimeSeries)
    others = [r for r in resolutions if r != DISPATCH_INTERVAL]
    isempty(others) || throw(
        ArgumentError(
            "the NEMDE inputs are derived on $(DISPATCH_INTERVAL) dispatch intervals, but the system has single time " *
                "series at $(join((string(Dates.canonicalize(Dates.CompoundPeriod(r))) for r in others), ", ")); build it with nem_system(db, NEMDEConfiguration(); date_range)",
        ),
    )
    return
end


# The NEM devices of `sys` that can carry offers.
_bidding_devices(sys::PSY.System) = Iterators.flatten(
    (PSY.get_components(T, sys) for T in (PSY.Generator, PSY.ControllableLoad, PSY.Storage)),
)

# The grid every single time series of `sys` sits on: their shared first timestamp, length and resolution.
function _nemde_grid(sys::PSY.System)
    initial, n = PSY.check_time_series_consistency(sys, PSY.SingleTimeSeries)
    resolutions = PSY.get_time_series_resolutions(sys; time_series_type = PSY.SingleTimeSeries)
    # A system without single time series has an empty grid.
    resolution = isempty(resolutions) ? DISPATCH_INTERVAL : only(resolutions)
    return initial:resolution:(initial + (n - 1) * resolution)
end

# The values of a bid or telemetry field of `device` on `grid`: `absent` repeated for a `nothing` field, a static
# value repeated, and a series key read from storage. With `field` given, the value must be a series key and a
# static one throws, naming `field`.
function _values_on_grid(device, value, grid; absent = NaN, field::Union{Nothing, Symbol} = nothing)
    n = length(grid)
    if !isnothing(field) && !(value isa IS.StaticTimeSeriesKey)
        throw(
            ArgumentError(
                "\"$(PSY.get_name(device))\" has a static `$(field)` field; the NEMDE inputs need series-backed " *
                    "bid inputs (offer curves included), as set_market_bids! writes them.",
            ),
        )
    end
    isnothing(value) && return fill(absent, n)
    value isa IS.StaticTimeSeriesKey || return fill(value isa Real ? Float64(value) : value, n)
    series = IS.get_time_series_values(device, value; start_time = first(grid), len = n)
    return eltype(series) <: Real ? Float64.(series) : series
end

# `field` of `device`'s energy bid on `side` on `grid`; `NaN` where the device has no bid on that side or the bid has no field.
function _energy_bid_values(device, side::OfferSide, field::Symbol, grid)
    cost = _nem_offer_cost(device)
    bid = isnothing(cost) ? nothing : _energy_bid(cost, side)
    return _values_on_grid(device, isnothing(bid) ? nothing : getproperty(bid, field), grid)
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
