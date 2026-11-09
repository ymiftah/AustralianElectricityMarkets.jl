"""
    NEMUnitState(initial_mw, dispatch_mode)

A NEM unit's state at the start of an interval, in natural units.

# Fields
- `initial_mw`: the output at the start of the interval, MW.
- `dispatch_mode`: the fast-start dispatch mode, from 0 to 4.
"""
struct NEMUnitState
    initial_mw::Float64
    dispatch_mode::Int
end


"""
    StateSource

Supertype for the sources of a unit's state: [`ObservedState`](@ref) reads AEMO's published state and
[`SimulatedState`](@ref) takes the previous interval's solution. A source carries whatever it needs in its
own fields, such as a previous solution or a fast-start mode history; [`unit_state`](@ref)`(source, device, t)`
is the whole interface that callers use.
"""
abstract type StateSource end


"""
    ObservedState()

The [`StateSource`](@ref) that reads a unit's [`NEMObservedState`](@ref) from the system.
"""
struct ObservedState <: StateSource end


"""
    SimulatedState()

The [`StateSource`](@ref) that takes the previous interval's solution. Not implemented yet: [`unit_state`](@ref)
throws an `ArgumentError` for it.
"""
struct SimulatedState <: StateSource end


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
    AustralianElectricityMarkets.has_registration(device) || return false
    registration = AustralianElectricityMarkets.get_registration(device)
    return !AustralianElectricityMarkets._is_registered(registration, t)
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
mode `0`. Throws an `ArgumentError` naming `device` and `t` when it is not a NEM device with an
observed state, when the observed dispatch mode at an observed stamp is not finite, and for a
[`SimulatedState`](@ref), which is not implemented yet.
"""
function unit_state(::ObservedState, device, t::DateTime)
    observed = AustralianElectricityMarkets.get_observed_state(device)
    dispatch_mode = _state_value(device, observed, :dispatch_mode, t)
    if !isfinite(dispatch_mode)
        _is_unobserved_stamp(device, t) && return NEMUnitState(0.0, 0)
        throw(
            ArgumentError(
                "The dispatch mode of \"$(PSY.get_name(device))\" at $(t) is not finite. " *
                    "Check that the unit has a DISPATCHLOAD row at that stamp.",
            ),
        )
    end
    initial_mw = _state_value(device, observed, :initial_mw, t)
    return NEMUnitState(Float64(initial_mw), Int(dispatch_mode))
end

function unit_state(::SimulatedState, device, t::DateTime)
    throw(ArgumentError("SimulatedState is not implemented yet, so the state of $(PSY.get_name(device)) cannot be simulated"))
end


# The configured state source, shared by the replay build and the per-step parameter updates.
function _state_source()
    return ObservedState()
end


# The build's first-solve seed series, written from `_state_source()` before the forecasts are
# attached; later solves overwrite the same parameters from the state source each step.
const _INITIAL_MW_SEED_SERIES = "initial_mw_seed"
const _FIXED_LOAD_SEED_SERIES = "fixed_load_seed"
const _FIXED_LOAD_INVOKED_SEED_SERIES = "fixed_load_invoked_seed"

# The value of `field` at `t`: a key is read over one step, a static value is returned as stored.
function _state_value(device, observed, field::Symbol, t::DateTime)
    value = AustralianElectricityMarkets.bid_value(device, observed, field, t, 1)
    return value isa AbstractVector ? only(value) : value
end


# The starting output the build seeds the first solve with. It reads the same `unit_state` the
# per-step updates call, so a stamp the build does not observe seeds the same zero the update writes.
function _state_initial_mw(source::StateSource, device, t::DateTime)
    return unit_state(source, device, t).initial_mw
end


"""
    NEMFCASInputs(; service, side, offer, trapezium, agc_ramp)

The keys of one FCAS service's inputs on a device, for one side of its market. Throws an `ArgumentError`
when `service` is not an FCAS `BidType`.

# Fields
- `service`: the FCAS `BidType`.
- `side`: the `OfferSide` of the offer.
- `offer`: the derived FCAS offer curve series, a price-band series in MW against \$/MWh, or `nothing`.
- `trapezium`: the derived FCAS trapezium series, MW, or `nothing`.
- `agc_ramp`: the AGC ramp rate series, in the units the unit conditions publish, or `nothing`.
"""
struct NEMFCASInputs <: PSY.DeviceParameter
    service::AustralianElectricityMarkets.BidType
    side::AustralianElectricityMarkets.OfferSide
    offer::Union{Nothing, IS.TimeSeriesKey}
    trapezium::Union{Nothing, IS.TimeSeriesKey}
    agc_ramp::Union{Nothing, IS.TimeSeriesKey}
end

function NEMFCASInputs(; service, side, offer = nothing, trapezium = nothing, agc_ramp = nothing)
    service in AustralianElectricityMarkets.FCAS_BID_TYPES ||
        throw(ArgumentError("NEMFCASInputs needs an FCAS bid type, got $(service)"))
    return NEMFCASInputs(service, side, offer, trapezium, agc_ramp)
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
- `energy_availability`: the derived energy availability series, system-base per unit.
- `energy_availability_decremental`: the derived decremental energy availability series, system-base per unit.
- `uigf`: the unit initial generation forecast, MW.
- `ramp_up`: the effective ramp-up limit series, MW/h.
- `ramp_down`: the effective ramp-down limit series, MW/h.
- `fcas`: one [`NEMFCASInputs`](@ref) per FCAS service and side with an offer.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
struct NEMDispatchInputs <: PSY.SupplementalAttribute
    energy_offer::Union{Nothing, IS.TimeSeriesKey}
    energy_offer_decremental::Union{Nothing, IS.TimeSeriesKey}
    energy_availability::Union{Nothing, IS.TimeSeriesKey}
    energy_availability_decremental::Union{Nothing, IS.TimeSeriesKey}
    uigf::Union{Nothing, IS.TimeSeriesKey}
    ramp_up::Union{Nothing, IS.TimeSeriesKey}
    ramp_down::Union{Nothing, IS.TimeSeriesKey}
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
