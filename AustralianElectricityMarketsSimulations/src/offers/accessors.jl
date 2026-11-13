"""
    NEMEnergyOffer

One side of a unit's energy offer, as attached by [`set_effective_offers!`](@ref): its price-band
curves over the offer's timestamps.

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


"""
    get_energy_offer(device, side::OfferSide) -> Union{Nothing, NEMEnergyOffer}

`device`'s energy offer on `side`, read from the `"energy_offer"` series of that side.

# Arguments
- `device`: the bidding device.
- `side`: the [`OfferSide`](@ref) to read.

# Returns
A [`NEMEnergyOffer`](@ref), or `nothing` when `device` carries no NEM unit data, has no energy
bid on `side`, or the offer is not attached.
"""
function get_energy_offer(device, side::OfferSide)
    cost = _nem_offer_cost(device)
    isnothing(cost) && return nothing
    any(b -> AustralianElectricityMarkets._energy_offer_side(b.direction) == side, get_energy_bids(cost)) || return nothing
    name = energy_offer_series_name(side)
    PSY.has_time_series(device, PSY.SingleTimeSeries, name) || return nothing
    ts = PSY.get_time_series(PSY.SingleTimeSeries, device, name)
    series = PSY.get_time_series_array(PSY.SingleTimeSeries, device, name)
    return NEMEnergyOffer(side, PSY.TimeSeries.timestamp(series), IS.get_resolution(ts), collect(values(series)))
end


"""
    get_initial_mw(component, initial_time, horizon) -> Vector{Float64}

Window of `component`'s observed `initial_mw` ([`set_unit_conditions!`](@ref), `DISPATCHLOAD.INITIALMW`,
net MW for a battery), `horizon` steps from `initial_time`, in `component`'s `System`'s current display units.

# Returns
`Vector{Float64}`.
"""
function get_initial_mw(component, initial_time, horizon::Integer)
    return _unit_window(component, AustralianElectricityMarkets.get_observed_state(component).initial_mw, initial_time, horizon)
end


# `key`'s raw values on `component` over `horizon` steps from `initial_time`; a static `key` is repeated.
function _raw_window(component, key, initial_time, horizon::Integer)
    key isa IS.StaticTimeSeriesKey || return fill(Float64(key), horizon)
    return Float64.(IS.get_time_series_values(component, key; start_time = initial_time, len = horizon))::Vector{Float64}
end


# `key`'s values on `component` per unit of the system base, over `horizon` steps from `initial_time`.
function _unit_values(component, key, initial_time, horizon::Integer)
    return _raw_window(component, key, initial_time, horizon) ./ PSY.get_system_base_power(component)
end


# `key`'s values on `component` per unit of the system base and in display units, or `nothing` for an absent key.
function _unit_window(component, key, initial_time, horizon::Integer)
    isnothing(key) && return nothing
    return _unit_values(component, key, initial_time, horizon) .* _fcas_units_multiplier(component)
end
