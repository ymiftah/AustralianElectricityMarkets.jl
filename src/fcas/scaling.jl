"""
    scale_fcas_trapezium(trap; agc_enablement_min = nothing, agc_enablement_max = nothing,
        agc_max_avail = nothing, uigf = nothing, is_regulation) -> FCASTrapezium

Applies AEMO *FCAS Model in NEMDE* §4's trapezium scaling to the offered `trap`: the AGC
enablement limits (§4.1) and AGC ramping capability (§4.2) for a regulation trapezium
(`is_regulation`), and the UIGF ceiling (§4.3) for a semi-scheduled unit. Each bound is
replaced only when the corresponding input is more restrictive than the bid's own value, and
the paired breakpoint slides to keep that side's slope angle (`low_breakpoint` with
`enablement_min`, `high_breakpoint` with `enablement_max`) equal to the bid's.

A `nothing` or `0.0` `agc_enablement_min`, `agc_enablement_max` or `agc_max_avail` is treated
as absent: no scaling on that leg. `uigf` has no such exemption — `0.0` clamps `enablement_max`
to zero, matching a semi-scheduled unit's weather forecast of no output.

# Arguments
- `trap`: the offered `FCASTrapezium`.
- `agc_enablement_min`, `agc_enablement_max`: telemetered AGC enablement limits, in `trap`'s
  units. Regulation only.
- `agc_max_avail`: telemetered AGC ramping capability (ramp rate × dispatch interval), in
  `trap`'s units. Regulation only.
- `uigf`: the semi-scheduled unit's weather ceiling, in `trap`'s units, or `nothing` for a
  scheduled unit.
- `is_regulation`: whether `trap` is a `RAISEREG`/`LOWERREG` trapezium.

# Returns
An `FCASTrapezium`.
"""
function scale_fcas_trapezium(
        trap::FCASTrapezium;
        agc_enablement_min::Union{Nothing, Float64} = nothing,
        agc_enablement_max::Union{Nothing, Float64} = nothing,
        agc_max_avail::Union{Nothing, Float64} = nothing,
        uigf::Union{Nothing, Float64} = nothing,
        is_regulation::Bool,
    )
    lower_slope = get_lower_slope_coeff(trap)
    upper_slope = get_upper_slope_coeff(trap)

    new_enablement_min = get_enablement_min(trap)
    new_enablement_max = get_enablement_max(trap)
    new_max_avail = get_max_avail(trap)

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

    # A trapezium narrowed past its own enablement span can't be represented; clamp rather
    # than invert.
    new_enablement_max = max(new_enablement_max, new_enablement_min)
    new_low_breakpoint = new_enablement_min + lower_slope * new_max_avail
    new_high_breakpoint = max(new_enablement_max - upper_slope * new_max_avail, new_low_breakpoint)

    return FCASTrapezium(;
        enablement_min = new_enablement_min, low_breakpoint = new_low_breakpoint,
        high_breakpoint = new_high_breakpoint, enablement_max = new_enablement_max,
        max_avail = new_max_avail, ramp_up_rate = get_ramp_up_rate(trap), ramp_down_rate = get_ramp_down_rate(trap),
    )
end
