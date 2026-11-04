"""
AEMO FCAS trapezium parameters for one device's offer into one FCAS market. Zero below
`enablement_min`, ramping to `max_avail` at `low_breakpoint`, flat until `high_breakpoint`,
ramping back to zero at `enablement_max` (AEMO, *FCAS Model in NEMDE*, §2). All MW/MW-per-minute
fields are as returned by `_get_fcas_trapezium`: MW under `NATURAL_UNITS`, per-unit of
the system base under `SYSTEM_BASE`.
"""
struct FCASTrapezium <: PSY.DeviceParameter
    enablement_min::Float64
    low_breakpoint::Float64
    high_breakpoint::Float64
    enablement_max::Float64
    max_avail::Float64
    "ROCUP, regulation FCAS only"
    ramp_up_rate::Union{Nothing, Float64}
    "ROCDOWN, regulation FCAS only"
    ramp_down_rate::Union{Nothing, Float64}
end


function FCASTrapezium(;
        enablement_min::Float64,
        low_breakpoint::Float64,
        high_breakpoint::Float64,
        enablement_max::Float64,
        max_avail::Float64,
        ramp_up_rate::Union{Nothing, Float64} = nothing,
        ramp_down_rate::Union{Nothing, Float64} = nothing,
    )
    return FCASTrapezium(
        enablement_min, low_breakpoint, high_breakpoint, enablement_max, max_avail,
        ramp_up_rate, ramp_down_rate,
    )
end


get_enablement_min(value::FCASTrapezium) = value.enablement_min

get_enablement_max(value::FCASTrapezium) = value.enablement_max

get_max_avail(value::FCASTrapezium) = value.max_avail

get_ramp_up_rate(value::FCASTrapezium) = value.ramp_up_rate

get_ramp_down_rate(value::FCASTrapezium) = value.ramp_down_rate


"LowerSlopeCoeff, AEMO *FCAS Model in NEMDE* §3: `(low_breakpoint - enablement_min) / max_avail`."
get_lower_slope_coeff(t::FCASTrapezium) = iszero(t.max_avail) ? 0.0 : (t.low_breakpoint - t.enablement_min) / t.max_avail

"UpperSlopeCoeff, AEMO *FCAS Model in NEMDE* §3: `(enablement_max - high_breakpoint) / max_avail`."
get_upper_slope_coeff(t::FCASTrapezium) = iszero(t.max_avail) ? 0.0 : (t.enablement_max - t.high_breakpoint) / t.max_avail


"""
    _validate_fcas_trapezium(t::FCASTrapezium, context::AbstractString) -> FCASTrapezium

Returns `t` if it is a well-formed FCAS bid trapezium (AEMO, *FCAS Model in NEMDE*, §2):
`enablement_min <= low_breakpoint <= high_breakpoint <= enablement_max` and `max_avail >= 0`.
Throws an `ArgumentError` naming `context` otherwise. A context callback is evaluated only
when validation fails.
"""
function _validate_fcas_trapezium(t::FCASTrapezium, context::AbstractString)
    return _validate_fcas_trapezium(t, () -> context)
end

function _validate_fcas_trapezium(t::FCASTrapezium, context::F) where {F <: Function}
    ordered = t.enablement_min <= t.low_breakpoint <= t.high_breakpoint <= t.enablement_max
    (ordered && t.max_avail >= 0.0) && return t
    description = context()
    throw(
        ArgumentError(
            "Malformed FCAS trapezium for $description: requires EnablementMin <= LowBreakpoint <= " *
                "HighBreakpoint <= EnablementMax and MaxAvail >= 0, got EnablementMin = " *
                "$(t.enablement_min), LowBreakpoint = $(t.low_breakpoint), HighBreakpoint = " *
                "$(t.high_breakpoint), EnablementMax = $(t.enablement_max), MaxAvail = $(t.max_avail).",
        ),
    )
end


"""
    Tuple(t::FCASTrapezium) -> NTuple{7, Float64}

Packs `t` as `(enablement_min, low_breakpoint, high_breakpoint, enablement_max, max_avail,
ramp_up_rate, ramp_down_rate)`, `NaN` for a `nothing` ramp rate.
"""
function Base.Tuple(t::FCASTrapezium)
    return (
        t.enablement_min, t.low_breakpoint, t.high_breakpoint, t.enablement_max, t.max_avail,
        something(t.ramp_up_rate, NaN), something(t.ramp_down_rate, NaN),
    )
end


"""
    FCASTrapezium(t::NTuple{7, Float64}) -> FCASTrapezium

Inverse of `Tuple(::FCASTrapezium)`: a `NaN` ramp rate becomes `nothing`.
"""
function FCASTrapezium(t::NTuple{7, Float64})
    return FCASTrapezium(
        t[1], t[2], t[3], t[4], t[5],
        isnan(t[6]) ? nothing : t[6],
        isnan(t[7]) ? nothing : t[7],
    )
end


"""
    scale_fcas_trapezium(trapezium; agc_enablement_min = nothing, agc_enablement_max = nothing,
        agc_max_avail = nothing, uigf = nothing, is_regulation) -> FCASTrapezium

Applies AEMO *FCAS Model in NEMDE* §4's trapezium scaling to the offered `trapezium`: the AGC
enablement limits (§4.1) and AGC ramping capability (§4.2) for a regulation trapezium
(`is_regulation`), and the UIGF ceiling (§4.3) for a semi-scheduled unit. Each bound is
replaced only when the corresponding input is more restrictive than the bid's own value, and
the paired breakpoint slides to keep that side's slope angle (`low_breakpoint` with
`enablement_min`, `high_breakpoint` with `enablement_max`) equal to the bid's. The breakpoints are
never clamped, so a squeezed result can have `high_breakpoint < low_breakpoint` (a trapezium whose
peak lies below `max_avail`) or `enablement_max < enablement_min` (no feasible FCAS).

A `nothing` or `0.0` `agc_enablement_min`, `agc_enablement_max` or `agc_max_avail` is treated
as absent: no scaling on that leg. `uigf` has no such exemption: `0.0` clamps `enablement_max`
to zero, matching a semi-scheduled unit's weather forecast of no output.

# Arguments
- `trapezium`: the offered `FCASTrapezium`.
- `agc_enablement_min`, `agc_enablement_max`: telemetered AGC enablement limits, in `trapezium`'s
  units. Regulation only.
- `agc_max_avail`: telemetered AGC ramping capability (ramp rate × dispatch interval), in
  `trapezium`'s units. Regulation only.
- `uigf`: the semi-scheduled unit's weather ceiling, in `trapezium`'s units, or `nothing` for a
  scheduled unit.
- `is_regulation`: whether `trapezium` is a `RAISEREG`/`LOWERREG` trapezium.

# Returns
An `FCASTrapezium`.
"""
function scale_fcas_trapezium(
        trapezium::FCASTrapezium;
        agc_enablement_min::Union{Nothing, Float64} = nothing,
        agc_enablement_max::Union{Nothing, Float64} = nothing,
        agc_max_avail::Union{Nothing, Float64} = nothing,
        uigf::Union{Nothing, Float64} = nothing,
        is_regulation::Bool,
    )
    lower_slope = get_lower_slope_coeff(trapezium)
    upper_slope = get_upper_slope_coeff(trapezium)

    new_enablement_min = get_enablement_min(trapezium)
    new_enablement_max = get_enablement_max(trapezium)
    new_max_avail = get_max_avail(trapezium)

    if is_regulation
        if !isnothing(agc_enablement_min) && !iszero(agc_enablement_min)
            new_enablement_min = max(new_enablement_min, agc_enablement_min)
        end
        if !isnothing(agc_enablement_max) && !iszero(agc_enablement_max)
            new_enablement_max = min(new_enablement_max, agc_enablement_max)
        end
        if !isnothing(agc_max_avail) && !iszero(agc_max_avail)
            new_max_avail = min(new_max_avail, agc_max_avail)
        end
    end
    isnothing(uigf) || (new_enablement_max = min(new_enablement_max, uigf))

    new_low_breakpoint = new_enablement_min + lower_slope * new_max_avail
    new_high_breakpoint = new_enablement_max - upper_slope * new_max_avail

    return FCASTrapezium(;
        enablement_min = new_enablement_min, low_breakpoint = new_low_breakpoint,
        high_breakpoint = new_high_breakpoint, enablement_max = new_enablement_max,
        max_avail = new_max_avail, ramp_up_rate = get_ramp_up_rate(trapezium), ramp_down_rate = get_ramp_down_rate(trapezium),
    )
end

"""
A `(REGIONID, BIDTYPE)` FCAS market anchor. Carries no requirement or time series of its own;
the regional RHS lives on the governing [`GenericConstraint`](@ref)'s own `"rhs"` series.

# Fields
- `name`: `"<REGIONID>_<BIDTYPE>"`.
- `available`: whether it is enforced.
- `region`: the NEM region.
- `bid_type`: the FCAS market.
- `ext`: unused, reserved.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
mutable struct FCASService <: PSY.Service
    name::String
    available::Bool
    region::String
    bid_type::BidType
    ext::Dict{String, Any}
    internal::IS.InfrastructureSystemsInternal
end


function FCASService(;
        name::AbstractString,
        available::Bool = true,
        region::AbstractString,
        bid_type::BidType,
        ext::Dict{String, Any} = Dict{String, Any}(),
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return FCASService(String(name), available, String(region), bid_type, ext, internal)
end


PSY.get_available(value::FCASService) = value.available

PSY.set_available!(value::FCASService, val) = value.available = val

PSY.get_ext(value::FCASService) = value.ext

PSY.set_ext!(value::FCASService, val) = value.ext = val

PSY.supports_time_series(::FCASService) = false

get_region(value::FCASService) = value.region

get_bid_type(value::FCASService) = value.bid_type


"""
    fcas_service_name(region, bid_type) -> String
    fcas_service_name(device, bid_type) -> String

The name `"<REGIONID>_<BIDTYPE>"` of the [`FCASService`](@ref) for `bid_type` in `region`, or in the
area of `device`'s own bus.

# Arguments
- `region`: an `Area` name.
- `bid_type`: the FCAS market.

# Returns
A `String`.
"""
fcas_service_name(region::AbstractString, bid_type::BidType) = "$(region)_$(string(bid_type))"

function fcas_service_name(device::Device, bid_type::BidType)
    return fcas_service_name(get_name(get_area(get_bus(device))), bid_type)
end


"""
    fcas_service(device, bid_type) -> FCASService

The [`FCASService`](@ref) for `bid_type` that `device` contributes to, found among the services
attached to `device`. A device contributes to exactly one service per FCAS market, its region's.

# Arguments
- `device`: a `PowerSystems` device, attached to its services by [`add_fcas_services!`](@ref).
- `bid_type`: the FCAS market.

# Returns
The `FCASService`. Throws `ArgumentError` if `device` has no such service or more than one.
"""
function fcas_service(device::PSY.Device, bid_type::BidType)
    services = _fcas_services(device, bid_type)
    isempty(services) && throw(
        ArgumentError("\"$(get_name(device))\" contributes to no $(string(bid_type)) FCASService."),
    )
    length(services) == 1 || throw(
        ArgumentError(
            "\"$(get_name(device))\" contributes to $(length(services)) $(string(bid_type)) " *
                "FCASServices ($(join(sort!(get_name.(services)), ", "))); expected exactly one.",
        ),
    )
    return only(services)
end

# The FCASServices for `bid_type` attached to `device`: empty when `device` does not bid that market.
function _fcas_services(device::PSY.Device, bid_type::BidType)
    return FCASService[svc for svc in PSY.get_services(device) if svc isa FCASService && get_bid_type(svc) == bid_type]
end


"""
    fcas_offer_series_name(service::FCASService, decremental::Bool) -> String

Name of the time series holding a device's FCAS offer curve for `service`, the series of its
[`FCASService`](@ref) bid. The incremental curve is named by the service and the decremental one by
`PSY.get_decremental_service_bid_name`, as PowerSystems stores service bids.

# Arguments
- `service`: the FCAS service, one per region and [`BidType`](@ref).
- `decremental`: `true` for the load-side (`LOAD`) curve, `false` for the generation-side one.

# Returns
A `String`.
"""
function fcas_offer_series_name(service::FCASService, decremental::Bool)
    return decremental ? PSY.get_decremental_service_bid_name(service) : PSY.get_name(service)
end
