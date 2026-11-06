IS.@scoped_enum(ScheduleType, SCHEDULED = 1, SEMI_SCHEDULED = 2, NON_SCHEDULED = 3)

@doc """
    ScheduleType

AEMO's `SCHEDULE_TYPE` of a registered unit: `SCHEDULED`, `SEMI_SCHEDULED` or `NON_SCHEDULED`.
""" ScheduleType


"""
    NEMRegistration(; schedule_type, gen_loss_factor, load_loss_factor, registered_from, registered_until)

A unit's registration as AEMO publishes it in `DUDETAILSUMMARY` and the loss factors. Every field is a
static value.

# Fields
- `schedule_type`: the [`ScheduleType`](@ref).
- `gen_loss_factor`: `TLF` x `DLF` on the generation side.
- `load_loss_factor`: `TLF` x `DLF` on the load side.
- `registered_from`: the start of the registration.
- `registered_until`: the end of the registration.
"""
struct NEMRegistration <: PSY.DeviceParameter
    schedule_type::ScheduleType
    gen_loss_factor::Float64
    load_loss_factor::Float64
    registered_from::DateTime
    registered_until::DateTime
end

function NEMRegistration(;
        schedule_type::ScheduleType, gen_loss_factor, load_loss_factor,
        registered_from::DateTime, registered_until::DateTime,
    )
    return NEMRegistration(
        schedule_type, Float64(gen_loss_factor), Float64(load_loss_factor), registered_from, registered_until,
    )
end


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
