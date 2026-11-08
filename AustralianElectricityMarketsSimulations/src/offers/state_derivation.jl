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

Whether a participant fixed loading applies in the interval: `fixed_load` is positive and finite and
the unit is not in its fast-start profile ([`in_fast_start_profile`](@ref)). A `NaN` loading is one
AEMO did not publish, and a zero loading is none.

# Arguments
- `fixed_load`: the energy bid's `FIXEDLOAD` at the interval, MW, `NaN` where unpublished.
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.

# Returns
`Bool`.
"""
function fixed_load_invoked(fixed_load::Real, state::NEMUnitState)
    return !isnan(fixed_load) && fixed_load > 0.0 && !in_fast_start_profile(state)
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
    fcas_state_enabled(trap::FCASTrapezium, state::NEMUnitState; storage::Bool = false) -> Bool

Whether the unit's starting output lies inside the enablement span of `trap`, which AEMO's stranded
pre-condition requires for the offer to be enabled. A `NaN` starting output does not disable the
offer.

# Arguments
- `trap`: the FCAS trapezium.
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.
- `storage`: whether the device is a `PowerSystems.Storage`; its stranded point is its net output,
  while every other device's is `max(output, 0)`.

# Returns
`Bool`.
"""
function fcas_state_enabled(trap::FCASTrapezium, state::NEMUnitState; storage::Bool = false)
    isnan(state.initial_mw) && return true
    point = storage ? state.initial_mw : max(state.initial_mw, 0.0)
    return get_enablement_min(trap) <= point <= get_enablement_max(trap)
end


"""
    fcas_both_sides_state_enabled(gen_trap, load_trap, gen_ok, load_ok, state::NEMUnitState) -> (Bool, Bool)

The stranded pre-condition of a bidirectional unit's regulation offer on both sides. When both sides
pass their other pre-conditions (`gen_ok` and `load_ok`), both are enabled only while the starting
output lies between the load side's enablement minimum and the generation side's enablement maximum;
otherwise the side that passes them is enabled only inside its own enablement span.

# Arguments
- `gen_trap`, `load_trap`: the generation-side and load-side FCAS trapeziums.
- `gen_ok`, `load_ok`: whether each side passes its other enablement pre-conditions.
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.

# Returns
`(gen_enabled, load_enabled)` as `Bool`s.
"""
function fcas_both_sides_state_enabled(
        gen_trap::FCASTrapezium, load_trap::FCASTrapezium, gen_ok::Bool, load_ok::Bool, state::NEMUnitState,
    )
    mw = state.initial_mw
    combined = get_enablement_min(load_trap) <= mw <= get_enablement_max(gen_trap)
    gen_ok && load_ok && return (combined, combined)
    within(trap) = get_enablement_min(trap) <= mw <= get_enablement_max(trap)
    return (gen_ok && within(gen_trap), load_ok && within(load_trap))
end


"""
    fcas_ramping_limit(capability, upper::Bool, state::NEMUnitState) -> Float64

The joint energy and FCAS limit of one direction: `state.initial_mw` plus the AGC ramping
`capability` on the upper form (energy is dispatched and the regulation side delivered) and minus it
on the lower form. `capability` and the result are in the same unit as `state.initial_mw`.

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
interval, MW per minute, `(up, down)`. A unit that starts on the generation side raises output at its
generation-side rate and one that starts on the load side lowers it at its load-side rate. A unit
that would reach zero inside the interval instead ramps over the whole interval at a rate that
blends the two sides, so that it finishes the interval at its own rate from zero. A `NaN` rate marks
a side without a bid, and a unit bidding one side only keeps that side's rates.

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
        Float64(load_up)
    else
        _composite_up_ramp(state.initial_mw, gen_up, load_down, period_minutes)
    end
    down = if !has_load
        Float64(gen_down)
    elseif !has_gen
        Float64(load_down)
    else
        _composite_down_ramp(state.initial_mw, gen_down, load_up, period_minutes)
    end
    return (up, down)
end


# The composite increase: the generation rate from a non-negative start, zero when the load side
# cannot ramp down, the load side's own rate when it reaches zero only past the interval, else the
# blend.
function _composite_up_ramp(initial_mw::Real, gen_up::Real, load_down::Real, period::Real)
    initial_mw >= 0 && return Float64(gen_up)
    iszero(load_down) && return 0.0
    abs(initial_mw / load_down) >= period && return Float64(load_down)
    return ((period - abs(initial_mw / load_down)) * gen_up - initial_mw) / period
end


# The composite decrease: the load rate from a non-positive start, zero when the generation side
# cannot ramp down, the generation side's own rate when it reaches zero only past the interval, else
# the blend.
function _composite_down_ramp(initial_mw::Real, gen_down::Real, load_up::Real, period::Real)
    initial_mw <= 0 && return Float64(load_up)
    iszero(gen_down) && return 0.0
    abs(initial_mw / gen_down) >= period && return Float64(gen_down)
    return ((period - abs(initial_mw / gen_down)) * load_up + initial_mw) / period
end
