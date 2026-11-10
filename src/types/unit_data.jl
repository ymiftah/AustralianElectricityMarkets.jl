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
    agc_status::Union{IS.TimeSeriesKey, Bool}
    uigf::Union{Nothing, IS.TimeSeriesKey, Float64}
    ramp_up_limit::Union{IS.TimeSeriesKey, Float64}
    ramp_down_limit::Union{IS.TimeSeriesKey, Float64}
    raise_reg_enablement::Union{IS.TimeSeriesKey, NTuple{2, Float64}}
    lower_reg_enablement::Union{IS.TimeSeriesKey, NTuple{2, Float64}}
    raise_reg_max_avail::Union{IS.TimeSeriesKey, Float64}
    lower_reg_max_avail::Union{IS.TimeSeriesKey, Float64}
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
    initial_mw::Union{IS.TimeSeriesKey, Float64}
    dispatch_mode::Union{IS.TimeSeriesKey, Int}
end

function NEMObservedState(; initial_mw, dispatch_mode)
    mode = dispatch_mode isa IS.TimeSeriesKey ? dispatch_mode : Int(dispatch_mode)
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
    attached = collect(PSY.get_supplemental_attributes(NEMUnitData, device))
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
