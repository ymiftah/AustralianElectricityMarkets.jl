"""
    NEMEnergyOffer

One side of a unit's energy offer, as attached by [`set_energy_offer!`](@ref): its price-band curves
over the offer's timestamps.

# Fields
- `side::OfferSide`: the offer side.
- `timestamps::Vector{DateTime}`: one per curve.
- `resolution::Dates.Period`: the spacing of `timestamps`.
- `curves::Vector{PiecewiseStepData}`: the offer curves.
"""
struct NEMEnergyOffer
    side::OfferSide
    timestamps::Vector{DateTime}
    resolution::Dates.Period
    curves::Vector{PiecewiseStepData}
end


# The five NEM device types, whose operation cost is a `NEMOfferCost`.
const _NEMDevice = Union{NEMThermalGen, NEMHydroGen, NEMRenewableGen, NEMStorage, NEMLoad}

# `device`'s `NEMOfferCost`, or `nothing` for a device that is not a NEM type.
_nem_offer_cost(::Any) = nothing
_nem_offer_cost(device::_NEMDevice) = get_operation_cost(device)


"""
    get_energy_offer(device, side::OfferSide) -> Union{Nothing, NEMEnergyOffer}

`device`'s energy offer on `side`, read from the series keyed by the [`NEMEnergyBid`](@ref) of its
[`NEMOfferCost`](@ref).

# Arguments
- `device`: the bidding device.
- `side`: the [`OfferSide`](@ref) to read.

# Returns
A [`NEMEnergyOffer`](@ref), or `nothing` when `device` is not a NEM device type or has no energy
bid on `side`.
"""
function get_energy_offer(device, side::OfferSide)
    cost = _nem_offer_cost(device)
    isnothing(cost) && return nothing
    i = findfirst(b -> b.side == side, get_energy_bids(cost))
    isnothing(i) && return nothing
    ts = IS.get_time_series(device, get_energy_bids(cost)[i].curves)
    series = get_time_series_array(device, ts)
    return NEMEnergyOffer(side, timestamp(series), IS.get_resolution(ts), collect(values(series)))
end


"""
    NEMFCASOffer

One side of a unit's offer for one FCAS market over a window, as attached by
[`set_fcas_bids!`](@ref): a trapezium and an offer curve per interval.

# Fields
- `service::BidType`: the FCAS market.
- `side::OfferSide`: the offer side.
- `trapeziums::Vector{FCASTrapezium}`: one per interval.
- `curves::Vector{PiecewiseStepData}`: one per interval.
"""
struct NEMFCASOffer
    service::BidType
    side::OfferSide
    trapeziums::Vector{FCASTrapezium}
    curves::Vector{PiecewiseStepData}
end


"""
    get_fcas_offer(component, service, side, initial_time, horizon; kwargs...) -> Union{Nothing, NEMFCASOffer}

`component`'s `service` offer on `side`, `horizon` steps from `initial_time`, in `component`'s
`System`'s current display units: the [`get_scaled_fcas_trapezium`](@ref) trapeziums (`kwargs` are
passed to it), paired with the offer curves of `_get_fcas_offer_curve`.
Throws `ArgumentError` if `component` has no [`NEMFCASBid`](@ref) for `(service, side)`, either
series isn't attached, or they differ in length.

# Returns
A [`NEMFCASOffer`](@ref), or `nothing` when `component` is not a NEM device type.
"""
function get_fcas_offer(component, service::BidType, side::OfferSide, initial_time, horizon::Integer; kwargs...)
    cost = _nem_offer_cost(component)
    isnothing(cost) && return nothing
    any(b -> b.service == service && b.side == side, get_fcas_bids(cost)) || throw(
        ArgumentError(
            "\"$(get_name(component))\" has no FCAS bid for $(string(service)) on $(string(side)); " *
                "call set_fcas_service_bids! first.",
        ),
    )
    decremental = side == OfferSide.LOAD
    trapeziums = get_scaled_fcas_trapezium(component, service, initial_time, horizon; decremental, kwargs...)
    curves = _get_fcas_offer_curve(component, service, initial_time, horizon; decremental)
    _require_equal_length(trapeziums, curves, service, component)
    return NEMFCASOffer(service, side, trapeziums, curves)
end
