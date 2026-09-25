"""
    energy_bounds(; initial_mw, ramp_up_rate, ramp_down_rate, max_avail, min_load, uigf,
        is_semi_scheduled)

Physical energy dispatch bounds for one unit in one interval, applied in NEMDE's order: the
upper bound is the lesser of the ramp-up limit from `initial_mw` and the greater of `max_avail`
and the ramp-down floor from `initial_mw`, then the UIGF weather ceiling for semi-scheduled
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
    ramp_up_limit = initial_mw + ramp_up_rate * DISPATCH_INTERVAL_HOURS
    ramp_down_floor = initial_mw - ramp_down_rate * DISPATCH_INTERVAL_HOURS

    upper = min(ramp_up_limit, max(max_avail, ramp_down_floor))
    if is_semi_scheduled && !isnothing(uigf)
        upper = min(upper, uigf)
    end
    lower = max(ramp_down_floor, 0.0)
    if initial_mw > 0.0 && min_load > 0.0
        lower = max(lower, min(min_load, upper))
    end
    lower = min(lower, upper)
    return (lower = lower, upper = upper)
end

"""
    scale_trapezium(trap; uigf, agc_ramp_mw, is_regulation)

Applies NEMDE's trapezium scaling to an offered [`FCASTrapezium`](@ref): the UIGF ceiling for
semi-scheduled units, and the telemetered AGC ramp cap for regulation services. A thin
single-interval wrapper over root's [`scale_fcas_trapezium`](@ref) (§4.1's AGC enablement-limit
scaling is not wired in here - this replication path has no telemetered AGC enablement input).

# Arguments
- `trap`: the offered trapezium.
- `uigf`: weather ceiling in MW, or `nothing` for scheduled units.
- `agc_ramp_mw`: MW deliverable within the interval at the telemetered AGC ramp rate, or
  `nothing` when unavailable.
- `is_regulation`: whether this is `RAISEREG`/`LOWERREG`; the AGC cap applies only to those.

# Returns
An [`FCASTrapezium`](@ref).
"""
function scale_trapezium(
        trap::FCASTrapezium;
        uigf::Union{Nothing, Float64},
        agc_ramp_mw::Union{Nothing, Float64},
        is_regulation::Bool,
    )
    return scale_fcas_trapezium(trap; agc_max_avail = agc_ramp_mw, uigf = uigf, is_regulation = is_regulation)
end
