# The key of `device`'s `SingleTimeSeries` named `name`.
function _series_key(device, name::AbstractString)
    for key in IS.get_time_series_keys(device)
        key isa IS.StaticTimeSeriesKey && IS.get_name(key) == name && return key
    end
    throw(ArgumentError("\"$(get_name(device))\" has no SingleTimeSeries named \"$name\"."))
end

"""
    set_fcas_offer!(sys, device, service, side, curves) -> Nothing

Stores `curves`, an FCAS offer curve per interval in MW and \$/MW, on `device` as the series
`fcas_offer_<service>` (suffixed `_decremental` for the `LOAD` side), replacing a series of that
name already on it. A call on a device whose operation cost is a [`NEMOfferCost`](@ref) also records
the series, with the device's `fcas_trapezium_<service>` series for `side`, as its bid for
`(service, side)`; a repeat call replaces that bid. Other devices keep their operation cost.

# Arguments
- `sys`: the `System` holding `device`.
- `device`: the bidding device, which must have an [`FCASService`](@ref) of `service`.
- `service`: the FCAS market, a [`BidType`](@ref).
- `side`: the [`OfferSide`](@ref) of the offer.
- `curves`: a `SingleTimeSeries` of `PiecewiseStepData`; its name is replaced.

# Returns
`nothing`.
"""
function set_fcas_offer!(sys, device::PSY.StaticInjection, service::BidType, side::OfferSide, curves::SingleTimeSeries)
    eltype(values(IS.get_data(curves))) <: PiecewiseStepData || throw(
        ArgumentError("FCAS offer curves must be a SingleTimeSeries of PiecewiseStepData."),
    )
    isempty(_fcas_services(device, service)) && throw(
        ArgumentError("\"$(get_name(device))\" has no FCASService for $(string(service))."),
    )
    name = fcas_series_name("fcas_offer", service, side)
    cost = get_operation_cost(device)
    trapezium = nothing
    if cost isa NEMOfferCost
        trapezium = _series_key(device, fcas_series_name("fcas_trapezium", service, side))
    end
    ts = SingleTimeSeries(; name, data = IS.get_data(curves), resolution = IS.get_resolution(curves))
    replace_single_series!(sys, device, ts)
    if cost isa NEMOfferCost
        _set_fcas_bid!(cost, NEMFCASBid(service, side, _series_key(device, name), trapezium))
    end
    return
end


"""
    set_energy_offer!(sys, device, side, curves) -> Nothing

Stores `curves`, an energy offer curve per interval in MW and \$/MWh, on `device` as the series
`energy_offer` (suffixed `_decremental` for the `LOAD` side), replacing a series of that name
already on it. A call on a device whose operation cost is a [`NEMOfferCost`](@ref) also records the
series, with the device's `MAXAVAIL` series for `side` ([`energy_max_avail_series_name`](@ref)), as its energy bid for `side`; a
repeat call replaces that bid. Other devices keep their operation cost.

# Arguments
- `sys`: the `System` holding `device`.
- `device`: the bidding device.
- `side`: the [`OfferSide`](@ref) of the offer.
- `curves`: a `SingleTimeSeries` of `PiecewiseStepData`; its name is replaced.

# Returns
`nothing`.
"""
function set_energy_offer!(sys, device::PSY.StaticInjection, side::OfferSide, curves::SingleTimeSeries)
    eltype(values(IS.get_data(curves))) <: PiecewiseStepData || throw(
        ArgumentError("Energy offer curves must be a SingleTimeSeries of PiecewiseStepData."),
    )
    name = energy_offer_series_name(side)
    cost = get_operation_cost(device)
    max_avail = nothing
    if cost isa NEMOfferCost
        max_avail = _series_key(device, energy_max_avail_series_name(device, side))
    end
    ts = SingleTimeSeries(; name, data = IS.get_data(curves), resolution = IS.get_resolution(curves))
    replace_single_series!(sys, device, ts)
    if cost isa NEMOfferCost
        _set_energy_bid!(cost, NEMEnergyBid(; side, curves = _series_key(device, name), max_avail))
    end
    return
end
