"""
    _max_active_power(availability, initial_mw, ramp_down_rate, Δ) -> Float64

The upper dispatch limit of one unit in one interval: its `availability`, raised to the ramp-down
floor `initial_mw - ramp_down_rate × Δ` when that floor is higher.

# Arguments
- `availability`: the dispatch envelope upper bound, in MW or per unit of the base.
- `initial_mw`: the unit's metered output at the start of the interval, in the same unit.
- `ramp_down_rate`: the ramp-down rate per hour, in the same unit.
- `Δ`: the interval length in hours.

# Returns
A `Float64` in the same unit as `availability`.
"""
function _max_active_power(availability::Real, initial_mw::Real, ramp_down_rate::Real, Δ::Real)
    return max(availability, initial_mw - ramp_down_rate * Δ)
end

"""
    max_active_power_floor(availability, ramp_down_rate, interval_hours, state::NEMUnitState) -> Float64

The upper dispatch limit of one unit in one interval: `availability`, raised to the ramp-down floor
`state.initial_mw - ramp_down_rate × interval_hours` when that floor is higher
([`_max_active_power`](@ref)). `availability`, `ramp_down_rate` and `state.initial_mw` are in the same
unit, and the result is in that unit.

# Arguments
- `availability`: the dispatch envelope upper bound.
- `ramp_down_rate`: the ramp-down rate per hour.
- `interval_hours`: the interval length in hours.
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.

# Returns
A `Float64`.
"""
function max_active_power_floor(
        availability::Real, ramp_down_rate::Real, interval_hours::Real, state::NEMUnitState,
    )
    return _max_active_power(availability, state.initial_mw, ramp_down_rate, interval_hours)
end


"""
    in_fast_start_profile(state::NEMUnitState) -> Bool

Whether the unit is in the part of its fast-start inflexibility profile that fixes its dispatch,
modes 1 (synchronising) and 2 (start-up). Modes 3 and 4 may generate above the profile and mode 0 is
offline.

# Arguments
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.

# Returns
`Bool`.
"""
function in_fast_start_profile(state::NEMUnitState)
    return state.dispatch_mode in (1, 2)
end


"""
    fixed_load_invoked(fixed_load, state::NEMUnitState) -> Bool

Whether a participant fixed loading applies in the interval: `fixed_load` is finite and positive and
the unit is not in its fast-start profile ([`in_fast_start_profile`](@ref)). A `NaN` loading is one
AEMO did not publish, a zero loading is none, and a negative loading is a target on the opposite
side of the bid, which its direction does not carry, so neither is invoked.

# Arguments
- `fixed_load`: the energy bid's `FIXEDLOAD` at the interval, MW, `NaN` where unpublished.
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.

# Returns
`Bool`.
"""
function fixed_load_invoked(fixed_load::Real, state::NEMUnitState)
    return isfinite(fixed_load) && fixed_load > 0.0 && !in_fast_start_profile(state)
end


"""
    effective_fixed_load(fixed_load, state::NEMUnitState) -> Float64

The fixed-loading target of one bid side in the interval, MW: `fixed_load` when
[`fixed_load_invoked`](@ref) and zero otherwise. The target is on the bid side's own axis, so a
storage device's load side is negated when the sides are netted.

# Arguments
- `fixed_load`: the energy bid's `FIXEDLOAD` at the interval, MW, `NaN` where unpublished.
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.

# Returns
A `Float64` in MW.
"""
function effective_fixed_load(fixed_load::Real, state::NEMUnitState)
    return fixed_load_invoked(fixed_load, state) ? Float64(fixed_load) : 0.0
end


"""
    fcas_state_stranded_ok(trap::FCASTrapezium, state::NEMUnitState; storage::Bool = false) -> Bool

Whether the unit's starting output lies inside the enablement span of `trap`, AEMO *FCAS Model in
NEMDE* §5's stranded pre-condition. The caller ANDs the result with the other §5 conditions. A
`NaN` starting output is outside the span, so an unknown starting output leaves the offer disabled.

# Arguments
- `trap`: the FCAS trapezium.
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.
- `storage`: whether the device is a `PowerSystems.Storage`; its stranded point is its net output,
  while every other device's is `max(output, 0)`.

# Returns
`Bool`.
"""
function fcas_state_stranded_ok(trap::FCASTrapezium, state::NEMUnitState; storage::Bool = false)
    point = storage ? state.initial_mw : max(state.initial_mw, 0.0)
    return get_enablement_min(trap) <= point <= get_enablement_max(trap)
end


"""
    fcas_both_sides_stranded_ok(gen_trap, load_trap, gen_ok, load_ok, state::NEMUnitState) -> (Bool, Bool)

The stranded pre-condition of a bidirectional unit's regulation offer on both sides, as AEMO *FCAS
Model in NEMDE* §5 states it. When both sides pass their other pre-conditions (`gen_ok` and
`load_ok`), both are enabled only while the starting output lies between the load side's enablement
minimum and the generation side's enablement maximum; otherwise the side that passes them is
enabled only inside its own enablement span. The caller ANDs each result with that side's other §5
conditions, and a `NaN` starting output disables both sides.

# Arguments
- `gen_trap`, `load_trap`: the generation-side and load-side FCAS trapeziums.
- `gen_ok`, `load_ok`: whether each side passes its other enablement pre-conditions.
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.

# Returns
`(gen_enabled, load_enabled)` as `Bool`s.
"""
function fcas_both_sides_stranded_ok(
        gen_trap::FCASTrapezium, load_trap::FCASTrapezium, gen_ok::Bool, load_ok::Bool, state::NEMUnitState,
    )
    mw = state.initial_mw
    combined = get_enablement_min(load_trap) <= mw <= get_enablement_max(gen_trap)
    gen_ok && load_ok && return (combined, combined)
    within(trap) = get_enablement_min(trap) <= mw <= get_enablement_max(trap)
    return (gen_ok && within(gen_trap), load_ok && within(load_trap))
end


"""
    fcas_ramping_active(capability, state::NEMUnitState) -> Bool

Whether a regulation market's joint ramping row is active in the interval: the AGC ramping
`capability` is finite and non-zero and the unit's starting output is known. The caller ANDs the
result with the unit's enablement for the market and writes the inactive limit where it is false.

# Arguments
- `capability`: the AGC ramping capability over the interval, `0.0` where the ramp rate is absent.
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.

# Returns
`Bool`.
"""
function fcas_ramping_active(capability::Real, state::NEMUnitState)
    return isfinite(capability) && !iszero(capability) && !isnan(state.initial_mw)
end


"""
    fcas_joint_ramping_exempt(state::NEMUnitState, fast_start::Bool) -> Bool

Whether a unit's joint energy and FCAS ramping limits are not applied in the interval. AEMO's
*FCAS Model in NEMDE* footnote 11 to Table 3 excludes a fast-start unit that starts in dispatch mode
0, 1 or 2 from the joint ramping constraints. A unit without a fast-start profile is never exempt.

# Arguments
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.
- `fast_start`: whether the unit carries a fast-start inflexibility profile in the interval.

# Returns
`Bool`.
"""
function fcas_joint_ramping_exempt(state::NEMUnitState, fast_start::Bool)
    return fast_start && state.dispatch_mode in (0, 1, 2)
end


"""
    fcas_ramping_limit(capability, upper::Bool, state::NEMUnitState) -> Float64

The joint energy and FCAS limit of one direction: `state.initial_mw` plus the AGC ramping
`capability` on the upper form (energy is dispatched and the regulation side delivered) and minus it
on the lower form. A `PowerSystems.ControllableLoad`'s LOWERREG row takes the upper form
(`fcas_upper_regulation_service`). `capability` and the result are in the same unit as
`state.initial_mw`.

# Arguments
- `capability`: the AGC ramping capability over the interval.
- `upper`: whether the limit is the upper form.
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.

# Returns
A `Float64`.
"""
function fcas_ramping_limit(capability::Real, upper::Bool, state::NEMUnitState)
    return upper ? state.initial_mw + capability : state.initial_mw - capability
end


"""
    mnsp_ramp_envelope(initial_flow, up_rate, down_rate, interval_minutes) -> (Float64, Float64)

The flow envelope of an MNSP link about its metered starting flow, MW: at most
`up_rate × interval_minutes` above `initial_flow` and `down_rate × interval_minutes` below it. The
rates are MW per minute, the forward direction's limit on the flow's increase and the reverse
direction's limit on its decrease.

# Arguments
- `initial_flow`: the metered flow at the start of the interval, MW, `NaN` where unpublished.
- `up_rate`: the forward ramp rate, MW/min.
- `down_rate`: the reverse ramp rate, MW/min.
- `interval_minutes`: the interval length in minutes.

# Returns
`(upper, lower)` as `Float64`s in MW.
"""
function mnsp_ramp_envelope(
        initial_flow::Real, up_rate::Real, down_rate::Real, interval_minutes::Real,
    )
    return (initial_flow + up_rate * interval_minutes, initial_flow - down_rate * interval_minutes)
end


"""
    composite_ramp_rates(gen_up, gen_down, load_up, load_down, period_minutes, state::NEMUnitState) -> (Float64, Float64)

The up and down ramp rates of a scheduled bidirectional unit whose output may cross zero inside the
interval, MW per minute, `(up, down)` on the net-generation axis, where generation is positive and
consumption negative. A unit that starts on the generation side raises output at its generation-side
rate and one that starts on the load side lowers it at its load-side rate. A unit that would reach
zero inside the interval instead ramps over the whole interval at a rate that blends the two sides,
so that it finishes the interval at its own rate from zero. A `NaN` rate marks a side without a bid.
A generation bid's `ROCUP` and `ROCDOWN` are the unit's up and down rates. A load bid's `ROCUP` is
consumption rising, so it is the unit's down rate and its `ROCDOWN` is the up rate. A
`PowerSystems.ControllableLoad` takes `(ramp_up, ramp_down) = (down, up)`; no other device type
reverses the pair. A load-only unit returns `(load_down, load_up)`: at a non-negative start its up
rate is the load ramp-down rate, and its down rate the load ramp-up rate, with no blend because it
has no generation rate to compose with.

# Arguments
- `gen_up`, `gen_down`: the generation bid's `ROCUP` and `ROCDOWN`, MW/min, `NaN` without a generation bid.
- `load_up`, `load_down`: the load bid's `ROCUP` and `ROCDOWN`, MW/min, `NaN` without a load bid.
- `period_minutes`: the interval length in minutes.
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.

# Returns
`(up, down)` as `Float64`s in MW per minute.
"""
function composite_ramp_rates(
        gen_up::Real, gen_down::Real, load_up::Real, load_down::Real, period_minutes::Real,
        state::NEMUnitState,
    )
    has_gen = !isnan(gen_up) || !isnan(gen_down)
    has_load = !isnan(load_up) || !isnan(load_down)
    up = if !has_load
        Float64(gen_up)
    elseif !has_gen
        Float64(load_down)
    else
        _composite_up_ramp(state.initial_mw, gen_up, load_down, period_minutes)
    end
    down = if !has_load
        Float64(gen_down)
    elseif !has_gen
        Float64(load_up)
    else
        _composite_down_ramp(state.initial_mw, gen_down, load_up, period_minutes)
    end
    return (up, down)
end


# The composite increase: the generation rate from a non-negative start, zero when the load side
# cannot ramp down, the load rate when it reaches zero only past the interval, else the blend.
function _composite_up_ramp(initial_mw::Real, gen_up::Real, load_down::Real, period::Real)
    initial_mw >= 0 && return Float64(gen_up)
    iszero(load_down) && return 0.0
    abs(initial_mw / load_down) >= period && return Float64(load_down)
    return ((period - abs(initial_mw / load_down)) * gen_up - initial_mw) / period
end


# The composite decrease: the load rate from a non-positive start, zero when the generation side
# cannot ramp down, the generation rate when it reaches zero only past the interval, else the blend.
function _composite_down_ramp(initial_mw::Real, gen_down::Real, load_up::Real, period::Real)
    initial_mw <= 0 && return Float64(load_up)
    iszero(gen_down) && return 0.0
    abs(initial_mw / gen_down) >= period && return Float64(gen_down)
    return ((period - abs(initial_mw / gen_down)) * load_up + initial_mw) / period
end


"""
    mnsp_fixed_load(raw::Float64) -> NTuple{2, Float64}

The fixed-loading value and invocation flag of an MNSP link direction in one interval, from the bid's
`FIXEDLOAD` in MW: `(0.0, 0.0)` where AEMO publishes NULL (`NaN`), otherwise `(raw, 1.0)`.

# Arguments
- `raw`: the bid's `FIXEDLOAD` at the interval, MW, `NaN` where unpublished.

# Returns
`(value, invoked)`: the loading in MW and the invocation flag.
"""
function mnsp_fixed_load(raw::Float64)::NTuple{2, Float64}
    isnan(raw) && return (0.0, 0.0)
    return (raw, 1.0)
end
