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
passed to it) and the offer curves, both read from the bid's series.
Throws `ArgumentError` if `component` has no [`NEMFCASBid`](@ref) for `service` on `side`, or either
series isn't attached, or they differ in length.

# Returns
A [`NEMFCASOffer`](@ref), or `nothing` when `component` carries no NEM unit data.
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
    get_initial_mw(component, initial_time, horizon) -> Vector{Float64}

Window of `component`'s observed `initial_mw` ([`set_unit_conditions!`](@ref), `DISPATCHLOAD.INITIALMW`,
net MW for a battery), `horizon` steps from `initial_time`, in `component`'s `System`'s current display units.

# Returns
`Vector{Float64}`.
"""
function get_initial_mw(component, initial_time, horizon::Integer)
    return _unit_window(component, AustralianElectricityMarkets.get_observed_state(component).initial_mw, initial_time, horizon)
end


"""
    get_energy_availability(component, initial_time, horizon) -> Union{Nothing, Vector{Float64}}

Energy availability of `component` over `horizon` steps from `initial_time`, in `component`'s `System`'s
current display units. It reads the energy bid `MAXAVAIL` series, limited by the UIGF of a semi-scheduled
unit ([`effective_energy_availability`](@ref)). `nothing` when `component` has no energy bid, except that a
non-scheduled load without one reads zeros, and always `nothing` for a `PSY.Storage`.

# Returns
`Union{Nothing, Vector{Float64}}`.
"""
function get_energy_availability(component, initial_time, horizon::Integer)
    component isa PSY.Storage && return nothing
    side = only(energy_offer_sides(component))
    key = _bid_availability_key(component, side)
    if isnothing(key)
        AustralianElectricityMarkets.is_non_scheduled_load(component) || return nothing
        return zeros(horizon)
    end
    telemetry = AustralianElectricityMarkets.get_telemetry(component)
    max_avail = _unit_values(component, key, initial_time, horizon)
    ramp_up = _raw_window(component, telemetry.ramp_up_limit, initial_time, horizon)
    uigf = isnothing(telemetry.uigf) ? nothing : _unit_values(component, telemetry.uigf, initial_time, horizon)
    pinned = AustralianElectricityMarkets.is_non_scheduled_load(component)
    availability = effective_energy_availability(max_avail, uigf, ramp_up, pinned)
    return availability .* _fcas_units_multiplier(component)
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


# The `(min, max)` pair series `key` on `component` in display units, as its two vectors, or `nothing` for an absent key.
function _unit_pair_window(component, key, initial_time, horizon::Integer)
    isnothing(key) && return nothing
    pairs = key isa IS.StaticTimeSeriesKey ?
        IS.get_time_series_values(component, key; start_time = initial_time, len = horizon) : fill(key, horizon)
    base = PSY.get_system_base_power(component)
    multiplier = _fcas_units_multiplier(component)
    return ([p[1] / base * multiplier for p in pairs], [p[2] / base * multiplier for p in pairs])
end


"""
    get_storage_energy_max_avail(component, initial_time, horizon) -> Union{Nothing, NamedTuple}

`component`'s energy bid `MAXAVAIL` series for each direction, `horizon` steps from `initial_time`, in
`component`'s `System`'s current display units. Each direction is read from its own energy bid only.

# Returns
`(gen = Vector{Float64}, load = Vector{Float64})`, or `nothing` unless both directions'
energy bids have a `MAXAVAIL` series.
"""
function get_storage_energy_max_avail(component, initial_time, horizon::Integer)
    gen = _unit_window(component, _bid_availability_key(component, OfferSide.GEN), initial_time, horizon)
    load = _unit_window(component, _bid_availability_key(component, OfferSide.LOAD), initial_time, horizon)
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
    return (get_time_series_values(SingleTimeSeries, component, name; start_time = initial_time, len = horizon) .* multiplier)::Vector{Float64}
end


"""
    _fcas_trapezium_window(device, inputs, initial_time, horizon) -> Vector{FCASTrapezium}

The trapeziums of the FCAS bid keyed by `inputs`, `horizon` steps from `initial_time`, per unit of the
system base: element `i` is `fcas_trapezium_values` of the bid's four MW breakpoints and its `MAXAVAIL`
at that step. Throws `ArgumentError` naming the bid series when a step is malformed.

# Arguments
- `device`: the bidding device.
- `inputs`: the bid's keys, a `NEMFCASInputs` from [`_fcas_bid_inputs`](@ref).
- `initial_time`: the first step.
- `horizon`: the number of steps.

# Returns
`Vector{FCASTrapezium}`.
"""
function _fcas_trapezium_window(device, inputs, initial_time, horizon::Integer)
    points = IS.get_time_series_values(device, inputs.trapezium; start_time = initial_time, len = horizon)
    max_avail = IS.get_time_series_values(device, inputs.max_avail; start_time = initial_time, len = horizon)
    base = AustralianElectricityMarkets._fcas_system_base(device)
    name = IS.get_name(inputs.trapezium)
    return [
        AustralianElectricityMarkets._validate_fcas_trapezium(
            FCASTrapezium(fcas_trapezium_values(points[i], max_avail[i], base)),
            "\"$name\" on \"$(get_name(device))\" at step $i",
        ) for i in eachindex(points)
    ]
end


"""
    _get_fcas_trapezium(component, service, initial_time, horizon; decremental = false) -> Vector{FCASTrapezium}

The unscaled trapeziums of `component`'s FCAS bid for `service`, `horizon` steps from `initial_time`, in
`component`'s `System`'s current display units (MW under `NATURAL_UNITS`, per-unit of the system base under
`SYSTEM_BASE`). `decremental` selects the load-side bid. Throws `ArgumentError` if `component` has no such bid.

# Returns
`Vector{FCASTrapezium}`.
"""
function _get_fcas_trapezium(component, service::BidType, initial_time, horizon::Integer; decremental::Bool = false)
    inputs = _fcas_bid_inputs(component, service, offer_side(decremental))
    isnothing(inputs) && throw(
        ArgumentError(
            "\"$(get_name(component))\" has no FCAS bid for $(string(service))" *
                (decremental ? " (decremental)" : "") * "; call set_market_bids! first.",
        ),
    )
    multiplier = AustralianElectricityMarkets._fcas_units_multiplier(component)
    return [FCASTrapezium(Tuple(t) .* multiplier) for t in _fcas_trapezium_window(component, inputs, initial_time, horizon)]
end


"""
    get_scaled_fcas_trapezium(component, service, initial_time, horizon; decremental = false,
        resolution = Minute(5)) -> Vector{FCASTrapezium}

Like `_get_fcas_trapezium`, but applies [`scale_fcas_trapezium`](@ref) at every step
using the regulation enablement of `service` in `component`'s telemetry, its AGC ramping capability,
`"fcas_agc_ramp_rate_<service>"` (MW/h) times `resolution` (regulation `service`s only, from
[`set_unit_conditions!`](@ref)), and its telemetry UIGF, when attached. A `NaN` entry applies no scaling at that step. UIGF applies at every
step. For controllable loads, raise regulation uses the physical ramp-down rate and lower
regulation the ramp-up rate. `decremental` selects the load-side bid; the AGC
enablement/ramp/UIGF series are shared by both directions of the same device.

# Returns
`Vector{FCASTrapezium}`.
"""
function get_scaled_fcas_trapezium(
        component, service::BidType, initial_time, horizon::Integer; decremental::Bool = false,
        resolution::Dates.Period = Minute(5),
    )
    trapeziums = _get_fcas_trapezium(component, service, initial_time, horizon; decremental)
    is_regulation = service in FCAS_REGULATION_MARKETS
    telemetry = AustralianElectricityMarkets.get_telemetry(component)
    enablement = is_regulation ? _unit_pair_window(
            component,
            service == BidType.RAISEREG ? telemetry.raise_reg_enablement : telemetry.lower_reg_enablement,
            initial_time, horizon,
        ) : nothing
    agc_enablement_min, agc_enablement_max = isnothing(enablement) ? (nothing, nothing) : enablement
    agc_max_avail = is_regulation ?
        get_fcas_agc_ramp_capability(component, _fcas_ramp_rate_service(component, service), initial_time, horizon; resolution = resolution) : nothing
    input_at(series, i) = (isnothing(series) || isnan(series[i])) ? nothing : series[i]
    uigf = _unit_window(component, telemetry.uigf, initial_time, horizon)

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
its `"fcas_agc_ramp_rate_<service>"` series ([`nem_system`](@ref), MW/h) times
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
    get_fcas_agc_status(component, initial_time, horizon) -> Vector{Union{Nothing, Int}}

Window of `component`'s telemetered `agc_status` ([`set_unit_conditions!`](@ref), `DISPATCHLOAD.AGCSTATUS`),
`horizon` steps from `initial_time`: `1` while the unit is under AGC control and `0` otherwise, `nothing`
at an interval with no value.

# Returns
`Vector{Union{Nothing, Int}}`.
"""
function get_fcas_agc_status(component, initial_time, horizon::Integer)
    telemetry = AustralianElectricityMarkets.get_telemetry(component)
    values = _raw_window(component, telemetry.agc_status, initial_time, horizon)
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
