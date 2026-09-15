"""
AEMO FCAS trapezium parameters for one device's offer into one FCAS market. Zero below
`enablement_min`, ramping to `max_avail` at `low_breakpoint`, flat until `high_breakpoint`,
ramping back to zero at `enablement_max` (AEMO, *FCAS Model in NEMDE*, §2). All MW/MW-per-minute
fields are as returned by [`get_fcas_trapezium`](@ref): MW under `NATURAL_UNITS`, per-unit of
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
get_low_breakpoint(value::FCASTrapezium) = value.low_breakpoint
get_high_breakpoint(value::FCASTrapezium) = value.high_breakpoint
get_enablement_max(value::FCASTrapezium) = value.enablement_max
get_max_avail(value::FCASTrapezium) = value.max_avail
get_ramp_up_rate(value::FCASTrapezium) = value.ramp_up_rate
get_ramp_down_rate(value::FCASTrapezium) = value.ramp_down_rate

"LowerSlopeCoeff, AEMO *FCAS Model in NEMDE* §3: `(low_breakpoint - enablement_min) / max_avail`."
get_lower_slope_coeff(t::FCASTrapezium) = iszero(t.max_avail) ? 0.0 : (t.low_breakpoint - t.enablement_min) / t.max_avail
"UpperSlopeCoeff, AEMO *FCAS Model in NEMDE* §3: `(enablement_max - high_breakpoint) / max_avail`."
get_upper_slope_coeff(t::FCASTrapezium) = iszero(t.max_avail) ? 0.0 : (t.enablement_max - t.high_breakpoint) / t.max_avail

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
One device's bid into one FCAS market for one interval: a 10-band offer curve plus the
trapezium parameters for that market. Keyed by `service::BidType` (not a reserve name — FCAS
requirements are [`GenericConstraint`](@ref)s, not `PowerSystems.Reserve`s).
"""
struct FCASBid <: PSY.DeviceParameter
    service::BidType
    offer_curve::PSY.PiecewiseStepData
    trapezium::FCASTrapezium
end

get_service(value::FCASBid) = value.service
get_offer_curve(value::FCASBid) = value.offer_curve
get_trapezium(value::FCASBid) = value.trapezium
