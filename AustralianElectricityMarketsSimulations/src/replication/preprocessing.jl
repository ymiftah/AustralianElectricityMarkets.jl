const DISPATCH_INTERVAL_HOURS = 1 / 12

"""
    resolve_rebids(bids)

Keeps the latest rebid per `(DUID, BIDTYPE, DIRECTION)`, ordering by `VERSIONNO`. Participants
may rebid quantities up to gate closure, so the archive holds several rows per unit per
interval and only the last one was dispatched.

# Returns
A `DataFrame` with one row per `(DUID, BIDTYPE, DIRECTION)`.
"""
function resolve_rebids(bids::DataFrame)
    isempty(bids) && return bids
    sorted = sort(bids, [:DUID, :BIDTYPE, :DIRECTION, :VERSIONNO])
    return combine(groupby(sorted, [:DUID, :BIDTYPE, :DIRECTION]), last)
end

"""
    energy_bounds(; initial_mw, ramp_up_rate, ramp_down_rate, max_avail, min_load, uigf,
        is_semi_scheduled)

Physical energy dispatch bounds for one unit in one interval, applied in NEMDE's order: ramp
limits from `initial_mw`, then `MAXAVAIL`, then the UIGF weather ceiling for semi-scheduled
units, then `MINIMUMLOAD` for an online unit.

`uigf` caps semi-scheduled units unconditionally — `SEMIDISPATCHCAP = 0` means AEMO did not
actively curtail, not that the weather limit is absent.

# Returns
`(lower, upper)` in MW, guaranteed non-inverting.
"""
function energy_bounds(;
        initial_mw::Float64,
        ramp_up_rate::Float64,
        ramp_down_rate::Float64,
        max_avail::Float64,
        min_load::Float64,
        uigf::Union{Nothing, Float64},
        is_semi_scheduled::Bool,
    )
    upper = initial_mw + ramp_up_rate * DISPATCH_INTERVAL_HOURS
    lower = initial_mw - ramp_down_rate * DISPATCH_INTERVAL_HOURS

    upper = min(upper, max_avail)
    if is_semi_scheduled && !isnothing(uigf)
        upper = min(upper, uigf)
    end
    lower = max(lower, 0.0)
    if initial_mw > 0.0 && min_load > 0.0
        lower = max(lower, min(min_load, upper))
    end
    lower = min(lower, upper)
    return (lower = lower, upper = upper)
end

"""
NEMDE's *effective* FCAS trapezium for one unit, service and interval — the offered
[`FCASTrapezium`](@ref) after UIGF and AGC ramp-rate scaling. Kept separate from the offered
record so parsed archive data is never mutated.
"""
struct EffectiveTrapezium
    enablement_min::Float64
    low_breakpoint::Float64
    high_breakpoint::Float64
    enablement_max::Float64
    max_avail::Float64
end

"LowerSlopeCoeff: `(low_breakpoint - enablement_min) / max_avail`, zero when `max_avail` is zero."
lower_slope_coeff(t::EffectiveTrapezium) =
    iszero(t.max_avail) ? 0.0 : (t.low_breakpoint - t.enablement_min) / t.max_avail

"UpperSlopeCoeff: `(enablement_max - high_breakpoint) / max_avail`, zero when `max_avail` is zero."
upper_slope_coeff(t::EffectiveTrapezium) =
    iszero(t.max_avail) ? 0.0 : (t.enablement_max - t.high_breakpoint) / t.max_avail

"""
    scale_trapezium(trap; uigf, agc_ramp_mw, is_regulation)

Applies NEMDE's trapezium scaling to an offered [`FCASTrapezium`](@ref), in AEMO's order: UIGF
ceiling for semi-scheduled units, then the telemetered AGC ramp cap for regulation services.
Breakpoints pivot with the bound that moved, so slope coefficients are preserved rather than
silently steepened.

# Arguments
- `trap`: the offered trapezium.
- `uigf`: weather ceiling in MW, or `nothing` for scheduled units.
- `agc_ramp_mw`: MW deliverable within the interval at the telemetered AGC ramp rate, or
  `nothing` when unavailable.
- `is_regulation`: whether this is `RAISEREG`/`LOWERREG`; the AGC cap applies only to those.

# Returns
An [`EffectiveTrapezium`](@ref).
"""
function scale_trapezium(
        trap::FCASTrapezium;
        uigf::Union{Nothing, Float64},
        agc_ramp_mw::Union{Nothing, Float64},
        is_regulation::Bool,
    )
    enablement_min = get_enablement_min(trap)
    low_breakpoint = get_low_breakpoint(trap)
    high_breakpoint = get_high_breakpoint(trap)
    enablement_max = get_enablement_max(trap)
    max_avail = get_max_avail(trap)

    if !isnothing(uigf) && uigf < enablement_max
        high_breakpoint -= (enablement_max - uigf)
        enablement_max = uigf
    end

    if is_regulation && !isnothing(agc_ramp_mw) && agc_ramp_mw < max_avail
        # Hold both slopes while the plateau narrows to the ramp-limited availability.
        lower_slope = iszero(max_avail) ? 0.0 : (low_breakpoint - enablement_min) / max_avail
        upper_slope = iszero(max_avail) ? 0.0 : (enablement_max - high_breakpoint) / max_avail
        max_avail = agc_ramp_mw
        low_breakpoint = enablement_min + lower_slope * max_avail
        high_breakpoint = enablement_max - upper_slope * max_avail
    end

    high_breakpoint = max(high_breakpoint, low_breakpoint)
    enablement_max = max(enablement_max, enablement_min)
    return EffectiveTrapezium(
        enablement_min, low_breakpoint, high_breakpoint, enablement_max, max_avail,
    )
end
