"""
    StateSource

Supertype for the sources of a unit's state, such as [`ObservedState`](@ref), which reads AEMO's published state.
A source carries whatever it needs in its own fields; [`unit_state`](@ref)`(source, device, t)` is the whole
interface that callers use.
"""
abstract type StateSource end


"""
    ObservedState()

The [`StateSource`](@ref) that reads a unit's [`NEMObservedState`](@ref) from the system.
"""
struct ObservedState <: StateSource end


"""
    _is_unobserved_stamp(device, t::DateTime) -> Bool

Whether the build observes no dispatched state for `device` at `t`: the stamp is outside the device's
[`NEMRegistration`](@ref) span, where AEMO publishes no `DISPATCHLOAD` row, or the device is a pinned
non-scheduled load, which is held at zero output. A device without a registration is always observable.

# Arguments
- `device`: the NEM device.
- `t`: the first timestamp of the interval.

# Returns
`Bool`.
"""
function _is_unobserved_stamp(device, t::DateTime)
    AustralianElectricityMarkets.is_non_scheduled_load(device) && return true
    unit = AustralianElectricityMarkets._nem_unit_data(device)
    registration = isnothing(unit) ? nothing : unit.registration
    isnothing(registration) && return false
    return !AustralianElectricityMarkets._is_registered(registration, t)
end


# `_is_unobserved_stamp` for each of `stamps`, from one lookup of the device's registration.
function _unobserved_stamp_mask(device, stamps::AbstractVector{DateTime})
    n = length(stamps)
    AustralianElectricityMarkets.is_non_scheduled_load(device) && return fill(true, n)
    unit = AustralianElectricityMarkets._nem_unit_data(device)
    registration = isnothing(unit) ? nothing : unit.registration
    isnothing(registration) && return fill(false, n)
    return [!AustralianElectricityMarkets._is_registered(registration, t) for t in stamps]
end


"""
    unit_state(source::StateSource, device, t::DateTime) -> NEMUnitState

The state of `device` at the start of the interval beginning at `t`, read from `source`.

# Arguments
- `source`: the [`StateSource`](@ref).
- `device`: the NEM device.
- `t`: the first timestamp of the interval.

# Returns
The [`NEMUnitState`](@ref) for an [`ObservedState`](@ref). A stamp the build does not observe (see
[`_is_unobserved_stamp`](@ref)) resolves to the state the build seeds there, zero output in dispatch
mode `0`. A unit whose previous interval is outside its registration starts in dispatch mode `0` at
its first registered stamp, with its observed output. Throws an `ArgumentError` naming `device` and `t`
when it is not a NEM device with an observed state, when the observed dispatch mode at an observed stamp
is not finite.
"""
function unit_state(::ObservedState, device, t::DateTime)
    observed = AustralianElectricityMarkets.get_observed_state(device)
    dispatch_mode = _state_value(device, observed, Val(:dispatch_mode), t)
    if !isfinite(dispatch_mode)
        _is_unobserved_stamp(device, t) && return NEMUnitState(0.0, 0)
        if _is_unobserved_stamp(device, t - Minute(5))
            initial_mw = _state_value(device, observed, Val(:initial_mw), t)
            return NEMUnitState(Float64(initial_mw), 0)
        end
        throw(
            ArgumentError(
                "The dispatch mode of \"$(PSY.get_name(device))\" at $(t) is not finite. " *
                    "Check that the unit has a DISPATCHLOAD row at the previous interval (t - 5 minutes), " *
                    "which holds its dispatch mode.",
            ),
        )
    end
    initial_mw = _state_value(device, observed, Val(:initial_mw), t)
    return NEMUnitState(Float64(initial_mw), Int(dispatch_mode))
end


# The configured state source, shared by the replay build and the derivations.
function _state_source()
    return ObservedState()
end

# The build's first-solve seed series, written from `_state_source()` before the forecasts are
# attached. The first solve reads these series, which PowerSimulations does not update.
const _INITIAL_MW_SEED_SERIES = "initial_mw_seed"
const _FIXED_LOAD_SEED_SERIES = "fixed_load_seed"
const _FIXED_LOAD_INVOKED_SEED_SERIES = "fixed_load_invoked_seed"

# The value of `field` at `t`: a key is read over one step, a static value is returned as stored.
_state_value(device, observed, field::Symbol, t::DateTime) = _state_value(device, observed, Val(field), t)

function _state_value(device, observed, field::Val{F}, t::DateTime) where {F}
    value = AustralianElectricityMarkets.bid_value(device, observed, field, t, 1)
    return value isa AbstractVector ? only(value) : value
end


"""
    _state_initial_mw(source::StateSource, device, t::DateTime) -> Float64

The starting output in MW that seeds the first solve at the stamp `t`. Reads only the output, so
it does not need the dispatch mode.

# Arguments
- `source`: the [`StateSource`](@ref).
- `device`: the NEM device.
- `t`: the first timestamp of the interval.

# Returns
The output in MW: `0.0` at an unobserved stamp, otherwise the raw observed `initial_mw`.
"""
function _state_initial_mw(::ObservedState, device, t::DateTime)
    _is_unobserved_stamp(device, t) && return 0.0
    observed = AustralianElectricityMarkets.get_observed_state(device)
    return Float64(_state_value(device, observed, Val(:initial_mw), t))
end


"""
    _state_initial_mw_series(source::StateSource, device, stamps::AbstractVector{DateTime}) -> Vector{Float64}

The starting output in MW at each of `stamps`, as [`_state_initial_mw`](@ref) gives it stamp by stamp. Under
[`ObservedState`](@ref) with a key-backed `initial_mw`, the series is read once over the stamps and the
registration is looked up once per device. The stamps must be consecutive at the series' resolution.

# Arguments
- `source`: the [`StateSource`](@ref).
- `device`: the NEM device.
- `stamps`: the first timestamps of the intervals, consecutive at the series' resolution.

# Returns
A `Vector{Float64}` the length of `stamps`.
"""
function _state_initial_mw_series(::ObservedState, device, stamps::AbstractVector{DateTime})
    observed = AustralianElectricityMarkets.get_observed_state(device)
    values = IS.get_time_series_values(device, observed.initial_mw; start_time = first(stamps), len = length(stamps))
    unobserved = _unobserved_stamp_mask(device, stamps)
    return [unobserved[i] ? 0.0 : Float64(values[i]) for i in eachindex(stamps)]
end

function _state_initial_mw_series(source::StateSource, device, stamps::AbstractVector{DateTime})
    return [_state_initial_mw(source, device, t) for t in stamps]
end


"""
    NEMFCASInputs(; service, side, offer, trapezium, max_avail, agc_ramp)

The keys of one FCAS service's inputs on a device, for one side of its market. Throws an `ArgumentError`
when `service` is not an FCAS `BidType`.

# Fields
- `service`: the FCAS `BidType`.
- `side`: the `OfferSide` of the offer.
- `offer`: the FCAS offer curve series of the bid, a price-band series in MW against \$/MWh, or `nothing`.
- `trapezium`: the FCAS trapezium series of the bid, the four MW breakpoints, or `nothing`.
- `max_avail`: the FCAS `MAXAVAIL` series of the bid, MW, or `nothing`.
- `agc_ramp`: the AGC ramp rate series, in the units the unit conditions publish, or `nothing`.
"""
struct NEMFCASInputs <: PSY.DeviceParameter
    service::AustralianElectricityMarkets.BidType
    side::AustralianElectricityMarkets.OfferSide
    offer::Union{Nothing, IS.StaticTimeSeriesKey}
    trapezium::Union{Nothing, IS.StaticTimeSeriesKey}
    max_avail::Union{Nothing, IS.StaticTimeSeriesKey}
    agc_ramp::Union{Nothing, IS.StaticTimeSeriesKey}
end

function NEMFCASInputs(;
        service, side, offer = nothing, trapezium = nothing, max_avail = nothing, agc_ramp = nothing,
    )
    service in AustralianElectricityMarkets.FCAS_BID_TYPES ||
        throw(ArgumentError("NEMFCASInputs needs an FCAS bid type, got $(service)"))
    return NEMFCASInputs(service, side, offer, trapezium, max_avail, agc_ramp)
end

IS.deserialize(::Type{Vector{NEMFCASInputs}}, data::Vector) =
    NEMFCASInputs[AustralianElectricityMarkets._deserialize_device_parameter(d) for d in data]


"""
    NEMDispatchInputs(; energy_offer = nothing, energy_offer_decremental = nothing,
        energy_availability = nothing, energy_availability_decremental = nothing, uigf = nothing,
        ramp_up = nothing, ramp_down = nothing, fcas = NEMFCASInputs[])

The keys of a device's derived dispatch inputs, held on the device as a supplemental attribute. Each field
is a key of a series attached to the device, or `nothing` where the input is absent.

# Fields
- `energy_offer`: the derived incremental energy offer series, a price-band series in MW against \$/MWh.
- `energy_offer_decremental`: the derived decremental energy offer series, a price-band series in MW against \$/MWh.
- `energy_availability`: the key of the energy bid's `MAXAVAIL` series, MW. A non-scheduled load without an
  energy bid has the zero `MAXAVAIL` series that [`set_market_bids!`](@ref) writes.
- `energy_availability_decremental`: the key of the decremental energy bid's `MAXAVAIL` series, MW, with the
  same zero-series rule for a load.
- `uigf`: the unit initial generation forecast, MW.
- `ramp_up`: the effective ramp-up limit series, MW/h.
- `ramp_down`: the effective ramp-down limit series, MW/h.
- `fcas`: one [`NEMFCASInputs`](@ref) per FCAS service and side with an offer.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
struct NEMDispatchInputs <: PSY.SupplementalAttribute
    energy_offer::Union{Nothing, IS.StaticTimeSeriesKey}
    energy_offer_decremental::Union{Nothing, IS.StaticTimeSeriesKey}
    energy_availability::Union{Nothing, IS.StaticTimeSeriesKey}
    energy_availability_decremental::Union{Nothing, IS.StaticTimeSeriesKey}
    uigf::Union{Nothing, IS.StaticTimeSeriesKey}
    ramp_up::Union{Nothing, IS.StaticTimeSeriesKey}
    ramp_down::Union{Nothing, IS.StaticTimeSeriesKey}
    fcas::Vector{NEMFCASInputs}
    internal::IS.InfrastructureSystemsInternal
end

function NEMDispatchInputs(;
        energy_offer = nothing, energy_offer_decremental = nothing,
        energy_availability = nothing, energy_availability_decremental = nothing, uigf = nothing,
        ramp_up = nothing, ramp_down = nothing, fcas = NEMFCASInputs[],
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return NEMDispatchInputs(
        energy_offer, energy_offer_decremental, energy_availability, energy_availability_decremental,
        uigf, ramp_up, ramp_down, collect(NEMFCASInputs, fcas), internal,
    )
end

IS.get_internal(inputs::NEMDispatchInputs) = inputs.internal

# The telemetry of a replay unit, or `nothing` when it is unset or the device carries no unit data.
function _unit_telemetry(device)
    unit = AustralianElectricityMarkets._nem_unit_data(device)
    return isnothing(unit) ? nothing : unit.telemetry
end

# The observed state of a replay unit, or `nothing` when it is unset or the device carries no unit data.
function _unit_observed(device)
    unit = AustralianElectricityMarkets._nem_unit_data(device)
    return isnothing(unit) ? nothing : unit.observed_state
end
