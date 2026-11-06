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
[`SimulatedState`](@ref) takes the previous interval's solution.
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
    unit_state(source::StateSource, device, t::DateTime) -> NEMUnitState

The state of `device` at the start of the interval beginning at `t`, read from `source`.

# Arguments
- `source`: the [`StateSource`](@ref).
- `device`: the NEM device.
- `t`: the first timestamp of the interval.

# Returns
The [`NEMUnitState`](@ref). Throws an `ArgumentError` naming `device` when it is not a NEM device with an
observed state.
"""
function unit_state(::ObservedState, device, t::DateTime)
    observed = AustralianElectricityMarkets.get_observed_state(device)
    initial_mw = _state_value(device, observed, :initial_mw, t)
    dispatch_mode = _state_value(device, observed, :dispatch_mode, t)
    return NEMUnitState(Float64(initial_mw), Int(dispatch_mode))
end

function unit_state(::SimulatedState, device, t::DateTime)
    throw(ArgumentError("SimulatedState is not implemented yet, so the state of $(PSY.get_name(device)) cannot be simulated"))
end

# The value of `field` at `t`: a key is read over one step, a static value is returned as stored.
function _state_value(device, observed, field::Symbol, t::DateTime)
    value = AustralianElectricityMarkets.bid_value(device, observed, field, t, 1)
    return value isa AbstractVector ? only(value) : value
end


"""
    NEMFCASInputs(; service, side, offer, trapezium, agc_ramp)

The keys of one FCAS service's inputs on a device, for one side of its market.

# Fields
- `service`: the `BidType` of the FCAS service.
- `side`: the `OfferSide` of the offer.
- `offer`: the derived offer curve series, or `nothing`.
- `trapezium`: the derived trapezium series, or `nothing`.
- `agc_ramp`: the derived AGC ramp series, or `nothing`.
"""
struct NEMFCASInputs <: PSY.DeviceParameter
    service::AustralianElectricityMarkets.BidType
    side::AustralianElectricityMarkets.OfferSide
    offer::Union{Nothing, IS.TimeSeriesKey}
    trapezium::Union{Nothing, IS.TimeSeriesKey}
    agc_ramp::Union{Nothing, IS.TimeSeriesKey}
end

function NEMFCASInputs(; service, side, offer = nothing, trapezium = nothing, agc_ramp = nothing)
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
- `energy_offer`: the derived incremental energy offer series.
- `energy_offer_decremental`: the derived decremental energy offer series.
- `energy_availability`: the derived energy availability series, MW.
- `energy_availability_decremental`: the derived decremental energy availability series, MW.
- `uigf`: the unit initial generation forecast, MW.
- `ramp_up`: the effective ramp-up limit series.
- `ramp_down`: the effective ramp-down limit series.
- `fcas`: one [`NEMFCASInputs`](@ref) per FCAS service and side.
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
