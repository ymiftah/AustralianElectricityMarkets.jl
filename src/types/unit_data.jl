IS.@scoped_enum(ScheduleType, SCHEDULED = 1, SEMI_SCHEDULED = 2, NON_SCHEDULED = 3)

@doc """
    ScheduleType

AEMO's `SCHEDULE_TYPE` of a registered unit: `SCHEDULED`, `SEMI_SCHEDULED` or `NON_SCHEDULED`.
""" ScheduleType


"""
    NEMRegistration(; schedule_type, gen_loss_factor, load_loss_factor, registered_from, registered_until,
        commissioned = true)

A unit's registration as AEMO publishes it in `DUDETAILSUMMARY` and the loss factors. Every field is a
static value.

# Fields
- `schedule_type`: the [`ScheduleType`](@ref).
- `gen_loss_factor`: `TLF` x `DLF` on the generation side.
- `load_loss_factor`: `TLF` x `DLF` on the load side.
- `registered_from`: the start of the registration.
- `registered_until`: the end of the registration.
- `commissioned`: whether the unit's station is commissioned.
"""
struct NEMRegistration <: PSY.DeviceParameter
    schedule_type::ScheduleType
    gen_loss_factor::Float64
    load_loss_factor::Float64
    registered_from::DateTime
    registered_until::DateTime
    commissioned::Bool
end

function NEMRegistration(;
        schedule_type::ScheduleType, gen_loss_factor, load_loss_factor,
        registered_from::DateTime, registered_until::DateTime, commissioned::Bool = true,
    )
    return NEMRegistration(
        schedule_type, Float64(gen_loss_factor), Float64(load_loss_factor), registered_from,
        registered_until, commissioned,
    )
end


"""
    NEMStation(; station_id, station_name = nothing, postcode = nothing)

The station a unit belongs to, as AEMO publishes it in `STATION`, attached to the unit as a
supplemental attribute. Units at one station share one instance.

# Fields
- `station_id`: `STATIONID`.
- `station_name`: `STATIONNAME`, or `nothing` when unpublished.
- `postcode`: `POSTCODE`, or `nothing` when unpublished.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
struct NEMStation <: PSY.SupplementalAttribute
    station_id::String
    station_name::Union{String, Nothing}
    postcode::Union{String, Nothing}
    internal::IS.InfrastructureSystemsInternal
end

function NEMStation(;
        station_id::AbstractString, station_name = nothing, postcode = nothing,
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return NEMStation(
        String(station_id), _station_text(station_name), _station_text(postcode), internal,
    )
end

# A nullable STATION text value as a typed field: `missing` and `nothing` both mean absent.
_station_text(x::AbstractString) = String(x)
_station_text(::Any) = nothing

IS.get_internal(station::NEMStation) = station.internal


"""
    NEMTelemetry(; agc_status, uigf = nothing, ramp_up_limit, ramp_down_limit, raise_reg_enablement,
        lower_reg_enablement, raise_reg_max_avail, lower_reg_max_avail)

A unit's telemetered limits as AEMO publishes them in `DISPATCHLOAD`, in natural units. Each field is a
static value or a key of the time series that holds it on the unit, or `nothing` where AEMO publishes no
value.

# Fields
- `agc_status`: whether the unit is under AGC.
- `uigf`: the unit initial generation forecast, MW. Semi-scheduled units only.
- `ramp_up_limit`: `RAMPUPRATE`, MW/h, as published.
- `ramp_down_limit`: `RAMPDOWNRATE`, MW/h, as published.
- `raise_reg_enablement`: the `(min, max)` MW enablement of raise regulation.
- `lower_reg_enablement`: the `(min, max)` MW enablement of lower regulation.
- `raise_reg_max_avail`: the raise regulation maximum availability, MW.
- `lower_reg_max_avail`: the lower regulation maximum availability, MW.
"""
struct NEMTelemetry <: PSY.DeviceParameter
    agc_status::Union{IS.StaticTimeSeriesKey, Bool}
    uigf::Union{Nothing, IS.StaticTimeSeriesKey, Float64}
    ramp_up_limit::Union{IS.StaticTimeSeriesKey, Float64}
    ramp_down_limit::Union{IS.StaticTimeSeriesKey, Float64}
    raise_reg_enablement::Union{IS.StaticTimeSeriesKey, NTuple{2, Float64}}
    lower_reg_enablement::Union{IS.StaticTimeSeriesKey, NTuple{2, Float64}}
    raise_reg_max_avail::Union{IS.StaticTimeSeriesKey, Float64}
    lower_reg_max_avail::Union{IS.StaticTimeSeriesKey, Float64}
end

function NEMTelemetry(;
        agc_status, uigf = nothing, ramp_up_limit, ramp_down_limit, raise_reg_enablement,
        lower_reg_enablement, raise_reg_max_avail, lower_reg_max_avail,
    )
    return NEMTelemetry(
        agc_status, _bid_number(uigf), _bid_number(ramp_up_limit), _bid_number(ramp_down_limit),
        _bid_pair(raise_reg_enablement), _bid_pair(lower_reg_enablement),
        _bid_number(raise_reg_max_avail), _bid_number(lower_reg_max_avail),
    )
end

# A static `(min, max)` pair as `Float64`; JSON reads a tuple back as a vector. Any other value as is.
function _bid_pair(x::Union{Tuple{Real, Real}, AbstractVector})
    length(x) == 2 && all(v -> v isa Real, x) ||
        throw(ArgumentError("expected a (min, max) pair of two numbers, got $(x)"))
    return (Float64(x[1]), Float64(x[2]))
end

function _bid_pair(x)
    return x
end

function Base.:(==)(a::NEMTelemetry, b::NEMTelemetry)
    return all(f -> _field_equal(getfield(a, f), getfield(b, f)), fieldnames(NEMTelemetry))
end


"""
    NEMObservedState(; initial_mw, dispatch_mode)

AEMO's published unit state from `DISPATCHLOAD`, in natural units: the output at the start of the
interval and the fast-start dispatch mode. Each field is a static value or a key of the time series that
holds it on the unit.

# Fields
- `initial_mw`: `INITIALMW`, MW.
- `dispatch_mode`: `DISPATCHMODE`, the fast-start mode from 0 to 4.
"""
struct NEMObservedState <: PSY.DeviceParameter
    initial_mw::Union{IS.StaticTimeSeriesKey, Float64}
    dispatch_mode::Union{IS.StaticTimeSeriesKey, Int}
end

function NEMObservedState(; initial_mw, dispatch_mode)
    mode = dispatch_mode isa IS.StaticTimeSeriesKey ? dispatch_mode : Int(dispatch_mode)
    return NEMObservedState(_bid_number(initial_mw), mode)
end

function Base.:(==)(a::NEMObservedState, b::NEMObservedState)
    return all(f -> _field_equal(getfield(a, f), getfield(b, f)), fieldnames(NEMObservedState))
end


"""
    NEMUnitData(; offer = NEMOfferCost(), registration = nothing, telemetry = nothing,
        observed_state = nothing)

The NEM unit data of a stock device in a replay system, attached to it as a supplemental attribute: the
unit's offer, registration, telemetry and observed state. A `nothing` field is a value AEMO does not
publish for the unit.

# Fields
- `offer`: the [`NEMOfferCost`](@ref) of the unit.
- `registration`: the [`NEMRegistration`](@ref), or `nothing`.
- `telemetry`: the [`NEMTelemetry`](@ref), or `nothing`.
- `observed_state`: the [`NEMObservedState`](@ref), or `nothing`.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
mutable struct NEMUnitData <: PSY.SupplementalAttribute
    offer::NEMOfferCost
    registration::Union{Nothing, NEMRegistration}
    telemetry::Union{Nothing, NEMTelemetry}
    observed_state::Union{Nothing, NEMObservedState}
    internal::IS.InfrastructureSystemsInternal
end

function NEMUnitData(;
        offer::NEMOfferCost = NEMOfferCost(), registration = nothing, telemetry = nothing,
        observed_state = nothing,
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return NEMUnitData(offer, registration, telemetry, observed_state, internal)
end

IS.get_internal(unit::NEMUnitData) = unit.internal

# The unit data attached to `device`, or `nothing`; attachment allows at most one.
_nem_unit_data(::Any) = nothing

function _nem_unit_data(device::PSY.Component)
    attached = PSY.get_supplemental_attributes(NEMUnitData, device)::Vector{NEMUnitData}
    return isempty(attached) ? nothing : only(attached)
end

"""
    has_nem_unit_data(device) -> Bool

Whether `device` carries a [`NEMUnitData`](@ref). `false` for anything that is not a component.

# Arguments
- `device`: any component.

# Returns
`Bool`.
"""
has_nem_unit_data(device) = !isnothing(_nem_unit_data(device))

"""
    attach_nem_unit_data!(sys, device; offer = NEMOfferCost()) -> NEMUnitData

Attaches a fresh [`NEMUnitData`](@ref) with `offer` to `device` in `sys`, and returns it. Throws an
`ArgumentError` naming `device` when it already carries one, so repeat calls do not replace data.

# Arguments
- `sys`: the system that holds `device`.
- `device`: the component to attach the unit data to.
- `offer`: the [`NEMOfferCost`](@ref) of the unit.

# Returns
The attached [`NEMUnitData`](@ref).
"""
function attach_nem_unit_data!(sys::PSY.System, device::PSY.Component; offer::NEMOfferCost = NEMOfferCost())
    has_nem_unit_data(device) && throw(ArgumentError("$(PSY.get_name(device)) already has NEM unit data"))
    unit = NEMUnitData(; offer)
    PSY.add_supplemental_attribute!(sys, device, unit)
    return unit
end


"""
    NEM_DISPATCH_DEVICE_TYPES

The stock device types that replay systems build for NEM dispatch units, in the order
[`nem_dispatch_devices`](@ref) collects them. A replay unit is a device of one of these types that
carries a [`NEMUnitData`](@ref).
"""
const NEM_DISPATCH_DEVICE_TYPES = (
    PSY.ThermalStandard, PSY.HydroDispatch, PSY.RenewableDispatch, PSY.InterruptiblePowerLoad,
    PSY.EnergyReservoirStorage,
)

# The value of a unit data field, or an `ArgumentError` naming the device when it is unset.
function _require_unit_data(value, what::AbstractString, d)
    isnothing(value) && throw(ArgumentError("$(PSY.get_name(d)) has no $what; build it with nem_system"))
    return value
end

# The unit data of a device, or an `ArgumentError` when it has none.
function _stock_unit_data(d::PSY.Component, what::AbstractString)
    unit = _nem_unit_data(d)
    isnothing(unit) && throw(ArgumentError("$(PSY.get_name(d)) is not a NEM device, so it has no $what"))
    return unit
end

# The unit data of a device that is about to be written, or an `ArgumentError` when it has none.
function _writable_unit_data(d::PSY.Component)
    unit = _nem_unit_data(d)
    isnothing(unit) &&
        throw(ArgumentError("$(PSY.get_name(d)) has no NEM unit data; attach it with attach_nem_unit_data!"))
    return unit
end

"""
    get_registration(d) -> NEMRegistration

The [`NEMRegistration`](@ref) of the device `d`, read from its attached [`NEMUnitData`](@ref). Throws an
`ArgumentError` naming `d` when it has none.

# Arguments
- `d`: the device, which must carry a [`NEMUnitData`](@ref) with a registration.

# Returns
- The [`NEMRegistration`](@ref) of `d`.
"""
function get_registration(d::PSY.Component)
    return _require_unit_data(_stock_unit_data(d, "registration").registration, "registration", d)
end

"""
    get_telemetry(d) -> NEMTelemetry

The [`NEMTelemetry`](@ref) of the device `d`, read from its attached [`NEMUnitData`](@ref). Throws an
`ArgumentError` naming `d` when it has none.

# Arguments
- `d`: the device, which must carry a [`NEMUnitData`](@ref) with telemetry.

# Returns
- The [`NEMTelemetry`](@ref) of `d`.
"""
function get_telemetry(d::PSY.Component)
    return _require_unit_data(_stock_unit_data(d, "telemetry").telemetry, "telemetry", d)
end

"""
    get_observed_state(d) -> NEMObservedState

The [`NEMObservedState`](@ref) of the device `d`, read from its attached [`NEMUnitData`](@ref). Throws an
`ArgumentError` naming `d` when it has none.

# Arguments
- `d`: the device, which must carry a [`NEMUnitData`](@ref) with an observed state.

# Returns
- The [`NEMObservedState`](@ref) of `d`.
"""
function get_observed_state(d::PSY.Component)
    return _require_unit_data(_stock_unit_data(d, "observed state").observed_state, "observed state", d)
end

"""
    set_registration!(d, registration::Union{Nothing, NEMRegistration})

Sets the registration of the device `d` in its attached [`NEMUnitData`](@ref), replacing any earlier one.
Repeat calls overwrite. Throws an `ArgumentError` naming `d` when it has no unit data.

# Arguments
- `d`: the device to update.
- `registration`: the [`NEMRegistration`](@ref), or `nothing` to unset it.

# Returns
- `registration`.
"""
function set_registration!(d::PSY.Component, registration)
    _writable_unit_data(d).registration = registration
    return registration
end

"""
    set_telemetry!(d, telemetry::Union{Nothing, NEMTelemetry})

Sets the telemetry of the device `d` in its attached [`NEMUnitData`](@ref), replacing any earlier one.
Repeat calls overwrite. Throws an `ArgumentError` naming `d` when it has no unit data.

# Arguments
- `d`: the device to update.
- `telemetry`: the [`NEMTelemetry`](@ref), or `nothing` to unset it.

# Returns
- `telemetry`.
"""
function set_telemetry!(d::PSY.Component, telemetry)
    _writable_unit_data(d).telemetry = telemetry
    return telemetry
end

"""
    set_observed_state!(d, observed_state::Union{Nothing, NEMObservedState})

Sets the observed state of the device `d` in its attached [`NEMUnitData`](@ref), replacing any earlier one.
Repeat calls overwrite. Throws an `ArgumentError` naming `d` when it has no unit data.

# Arguments
- `d`: the device to update.
- `observed_state`: the [`NEMObservedState`](@ref), or `nothing` to unset it.

# Returns
- `observed_state`.
"""
function set_observed_state!(d::PSY.Component, observed_state)
    _writable_unit_data(d).observed_state = observed_state
    return observed_state
end
