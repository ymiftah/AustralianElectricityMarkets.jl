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
A [`NEMEnergyOffer`](@ref), or `nothing` when `device` is not a NEM device type, has no energy
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
    NEMFCASOffer

One side of a unit's offer for one FCAS market over a window, as attached by
[`set_effective_offers!`](@ref): a trapezium and an offer curve per interval.

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
passed to it) and the offer curves, read from the derived `"fcas_trapezium_<service>"` and
`"fcas_offer_<service>"` series.
Throws `ArgumentError` if `component` has no [`NEMFCASBid`](@ref) for `service` on `side`, or either
series isn't attached, or they differ in length.

# Returns
A [`NEMFCASOffer`](@ref), or `nothing` when `component` is not a NEM device type.
"""
function get_fcas_offer(component, service::BidType, side::OfferSide, initial_time, horizon::Integer; kwargs...)
    cost = _nem_offer_cost(component)
    isnothing(cost) && return nothing
    any(b -> b.service == service && AustralianElectricityMarkets._fcas_bid_side(component, b) == side, get_fcas_bids(cost)) || throw(
        ArgumentError(
            "\"$(get_name(component))\" has no FCAS bid for $(string(service)) on $(string(side)); " *
                "call set_market_bids! first.",
        ),
    )
    decremental = side == OfferSide.LOAD
    trapeziums = get_scaled_fcas_trapezium(component, service, initial_time, horizon; decremental, kwargs...)
    curves = _get_fcas_offer_curve(component, service, initial_time, horizon; decremental)
    _require_equal_length(trapeziums, curves, service, component)
    return NEMFCASOffer(service, side, trapeziums, curves)
end


"""
    get_initial_mw(component, initial_time, horizon) -> Union{Nothing, Vector{Float64}}

Full-series read of `component`'s `"initial_mw"` series ([`nem_system`](@ref),
`DISPATCHLOAD.INITIALMW`, net MW for a battery), `horizon` steps from `initial_time`, in
`component`'s `System`'s current display units. `nothing` if `component` carries no such series.

# Returns
`Union{Nothing, Vector{Float64}}`.
"""
function get_initial_mw(component, initial_time, horizon::Integer)
    return _read_dispatch_limit_series(component, NEM_SERIES.initial_mw, initial_time, horizon)
end


"""
    get_energy_availability(component, initial_time, horizon) -> Union{Nothing, Vector{Float64}}

Full-series read of `component`'s `"availability"` series ([`nem_system`](@ref),
`DISPATCHLOAD.AVAILABILITY`), `horizon` steps from `initial_time`, in `component`'s `System`'s
current display units. `nothing` if `component` carries no such series.

# Returns
`Union{Nothing, Vector{Float64}}`.
"""
function get_energy_availability(component, initial_time, horizon::Integer)
    return _read_dispatch_limit_series(component, NEM_SERIES.availability, initial_time, horizon)
end


"`component`'s `name` `SingleTimeSeries` over `horizon` steps from `initial_time`, in display units, or `nothing`."
function _read_dispatch_limit_series(component, name::AbstractString, initial_time, horizon::Integer)
    has_time_series(component, SingleTimeSeries, name) || return nothing
    values = get_time_series_values(SingleTimeSeries, component, name; start_time = initial_time, len = horizon)
    return values .* _fcas_units_multiplier(component)
end


"""
    get_storage_energy_max_avail(component, initial_time, horizon) -> Union{Nothing, NamedTuple}

`component`'s energy bid `MAXAVAIL` for each direction, as attached by
[`set_market_bids!`](@ref), `horizon` steps from `initial_time`, in `component`'s `System`'s
current display units.

# Returns
`(gen = Vector{Float64}, load = Vector{Float64})`, or `nothing` unless both directions'
series are attached.
"""
function get_storage_energy_max_avail(component, initial_time, horizon::Integer)
    gen, load = (_read_dispatch_limit_series(component, energy_max_avail_series_name(side), initial_time, horizon) for side in (OfferSide.GEN, OfferSide.LOAD))
    (isnothing(gen) || isnothing(load)) && return nothing
    return (; gen, load)
end


"""
    _read_optional_fcas_scaling_series(component, name, initial_time, horizon) -> Union{Nothing, Vector{Float64}}

Full-series read of `component`'s `name` `SingleTimeSeries`, `horizon` steps from
`initial_time`, in `component`'s `System`'s current display units. `nothing` if `component`
carries no such series; a `NaN` entry marks an interval with no input.
"""
function _read_optional_fcas_scaling_series(component, name::AbstractString, initial_time, horizon::Integer)
    has_time_series(component, SingleTimeSeries, name) || return nothing
    multiplier = _fcas_units_multiplier(component)
    return get_time_series_values(SingleTimeSeries, component, name; start_time = initial_time, len = horizon) .* multiplier
end


"""
    get_scaled_fcas_trapezium(component, service, initial_time, horizon; decremental = false,
        resolution = Minute(5)) -> Vector{FCASTrapezium}

Like `_get_fcas_trapezium`, but applies [`scale_fcas_trapezium`](@ref) at every step
using `component`'s `"fcas_agc_enablement_min_<service>"`/`"fcas_agc_enablement_max_<service>"`
series and its AGC ramping capability, `"fcas_agc_ramp_rate_<service>"` (MW/h) times
`resolution` (regulation `service`s only, from [`set_fcas_scaling_inputs!`](@ref)), and its
`"uigf"` series, when attached. A `NaN` entry applies no scaling at that step. UIGF applies at every
step. For controllable loads, raise regulation uses the physical ramp-down rate and lower
regulation the ramp-up rate. `decremental` selects the `DIRECTION == "LOAD"` trapezium series; the AGC
enablement/ramp/UIGF series are shared by both directions of the same device.

# Returns
`Vector{FCASTrapezium}`.
"""
function get_scaled_fcas_trapezium(
        component, service::BidType, initial_time, horizon::Integer; decremental::Bool = false,
        resolution::Dates.Period = Minute(5), trapezium_name::Union{Nothing, AbstractString} = nothing,
    )
    trapeziums = _get_fcas_trapezium(
        component, service, initial_time, horizon; decremental,
        name = something(trapezium_name, fcas_series_name("fcas_trapezium", service, decremental)),
    )
    is_regulation = service in FCAS_REGULATION_MARKETS
    agc_enablement_min = is_regulation ?
        _read_optional_fcas_scaling_series(component, fcas_series_name("fcas_agc_enablement_min", service), initial_time, horizon) : nothing
    agc_enablement_max = is_regulation ?
        _read_optional_fcas_scaling_series(component, fcas_series_name("fcas_agc_enablement_max", service), initial_time, horizon) : nothing
    agc_max_avail = is_regulation ?
        get_fcas_agc_ramp_capability(component, _fcas_ramp_rate_service(component, service), initial_time, horizon; resolution = resolution) : nothing
    input_at(series, i) = (isnothing(series) || isnan(series[i])) ? nothing : series[i]
    uigf = _read_optional_fcas_scaling_series(component, NEM_SERIES.uigf, initial_time, horizon)

    return [
        scale_fcas_trapezium(
            trapeziums[i];
            agc_enablement_min = input_at(agc_enablement_min, i),
            agc_enablement_max = input_at(agc_enablement_max, i),
            agc_max_avail = input_at(agc_max_avail, i),
            uigf = input_at(uigf, i),
            is_regulation = is_regulation,
        ) for i in eachindex(trapeziums)
    ]
end


"""
    get_fcas_agc_ramp_capability(component, service, initial_time, horizon; resolution = Minute(5)) -> Union{Nothing, Vector{Float64}}

`component`'s AGC ramping capability for regulation `service` (AEMO *FCAS Model in NEMDE* §4.2):
its `"fcas_agc_ramp_rate_<service>"` series ([`set_fcas_scaling_inputs!`](@ref), MW/h) times
`resolution`, `horizon` steps from `initial_time`, in `component`'s `System`'s current display
units, `NaN` at an interval with no ramp rate. `nothing` if `component` carries no such series.

# Returns
`Union{Nothing, Vector{Float64}}`.
"""
function get_fcas_agc_ramp_capability(
        component, service::BidType, initial_time, horizon::Integer; resolution::Dates.Period = Minute(5),
    )
    rate = _read_optional_fcas_scaling_series(component, fcas_series_name("fcas_agc_ramp_rate", service), initial_time, horizon)
    isnothing(rate) && return nothing
    return rate .* (Dates.value(Millisecond(resolution)) / 3_600_000)
end


"""
    get_fcas_agc_status(component, initial_time, horizon) -> Union{Nothing, Vector{Int}}

Full-series read of `component`'s `"fcas_agc_status"` `SingleTimeSeries`
([`set_fcas_scaling_inputs!`](@ref)), `horizon` steps from `initial_time`: `DISPATCHLOAD.AGCSTATUS`,
`1` while the unit is under AGC control and `0` otherwise, `nothing` at an interval with no
value. `nothing` if `component` carries no such series.

# Returns
`Union{Nothing, Vector{Union{Nothing, Int}}}`.
"""
function get_fcas_agc_status(component, initial_time, horizon::Integer)
    has_time_series(component, SingleTimeSeries, NEM_SERIES.fcas_agc_status) || return nothing
    values = get_time_series_values(SingleTimeSeries, component, NEM_SERIES.fcas_agc_status; start_time = initial_time, len = horizon)
    return Union{Nothing, Int}[isnan(v) ? nothing : round(Int, v) for v in values]
end


"""
    _require_equal_length(a, b, service, component)

`nothing` if `a` and `b` have the same length; otherwise an `ArgumentError` naming `service`
and `component`.
"""
function _require_equal_length(a::AbstractVector, b::AbstractVector, service::BidType, component)
    length(a) == length(b) || throw(
        ArgumentError(
            "FCAS trapezium series ($(length(a)) points) and offer curve series " *
                "($(length(b)) points) for $(string(service)) on \"$(get_name(component))\" " *
                "have different lengths - cannot pair them.",
        ),
    )
    return nothing
end
