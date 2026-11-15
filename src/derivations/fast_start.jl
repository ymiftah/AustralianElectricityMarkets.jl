# The fast-start commitment and inflexibility-profile rules of NEMDE's two dispatch runs: pure functions of a
# unit's starting state, its offered profile and the first run's energy target.


"""
    is_fast_start(profile) -> Bool

Whether an energy offer's fast-start profile makes the unit a fast-start unit in the interval: the profile is
set and one of `T1` to `T4` is positive. A profile of zeros, or `nothing`, is a slow-start offer.

# Arguments
- `profile`: the offer's [`FastStartProfile`](@ref) at the interval, or `nothing` without one.

# Returns
`Bool`.
"""
is_fast_start(::Nothing) = false
is_fast_start(profile::FastStartProfile) = any(>(0.0), (profile.t1, profile.t2, profile.t3, profile.t4))


"""
    fast_start_mode_length(profile::FastStartProfile, mode::Integer) -> Float64

The length in minutes of dispatch mode `mode` of `profile`: `T1` to `T4` for modes 1 to 4, and `0.0` for mode 0.

# Arguments
- `profile`: the [`FastStartProfile`](@ref).
- `mode`: the dispatch mode, from 0 to 4.

# Returns
A `Float64` in minutes. Throws an `ArgumentError` for a mode outside 0 to 4.
"""
function fast_start_mode_length(profile::FastStartProfile, mode::Integer)
    mode == 0 && return 0.0
    mode == 1 && return profile.t1
    mode == 2 && return profile.t2
    mode == 3 && return profile.t3
    mode == 4 && return profile.t4
    throw(ArgumentError("fast-start dispatch mode $mode is outside 0 to 4"))
end


"""
    fast_start_time_in_mode(mode, dispatch_mode_time, profile) -> Float64

The time in minutes a unit has spent in its starting dispatch mode, as NEMDE's `CurrentModeTime`: the previous
interval's `DISPATCHMODETIME`, capped at the length of `mode` in `profile`. It is `0.0` in mode 0 and for an offer
that is not fast-start ([`is_fast_start`](@ref)), and `NaN` when `dispatch_mode_time` is `NaN` in modes 1 to 4.

# Arguments
- `mode`: the starting dispatch mode, the previous interval's `DISPATCHMODE`, from 0 to 4.
- `dispatch_mode_time`: the previous interval's `DISPATCHMODETIME`, minutes, `NaN` where unpublished.
- `profile`: the offer's [`FastStartProfile`](@ref) at the interval, or `nothing` without one.

# Returns
A `Float64` in minutes.
"""
function fast_start_time_in_mode(mode::Integer, dispatch_mode_time::Real, profile::Union{Nothing, FastStartProfile})
    (mode == 0 || !is_fast_start(profile)) && return 0.0
    return min(Float64(dispatch_mode_time), fast_start_mode_length(profile, mode))
end


"""
    FastStartEndState(mode, time_in_mode, time_since_end_of_mode_two)

A fast-start unit's dispatch mode at the end of an interval, from [`fast_start_end_state`](@ref).

# Fields
- `mode`: the end dispatch mode, from 0 to 4.
- `time_in_mode`: the minutes in `mode` at the end of the interval.
- `time_since_end_of_mode_two`: the minutes of the interval after the unit left mode 2, for a unit that left mode
  2 during the interval, `nothing` otherwise.
"""
struct FastStartEndState
    mode::Int
    time_in_mode::Float64
    time_since_end_of_mode_two::Union{Nothing, Float64}
end


"""
    fast_start_end_state(start_mode, time_in_mode, profile, run1_mw; interval_minutes = 5.0) -> FastStartEndState

The end state of a fast-start unit after NEMDE's commitment run. A unit starting in mode 0 is committed when its
first-run energy target `run1_mw` is above 0 MW, entering mode 1 with 0 minutes in it. The unit then moves through
modes 1, 2 and 3, once each and in that order, leaving mode `k` when the time left in its segment, `T_k` less the
time in mode, is strictly less than the time left in the interval, and carrying the remainder into the next mode.
The end time in mode is 0 in mode 0 and capped at `T4` in mode 4; a unit never leaves mode 4.

# Arguments
- `start_mode`: the dispatch mode at the start of the interval, from 0 to 4.
- `time_in_mode`: the minutes in `start_mode` at the start of the interval ([`fast_start_time_in_mode`](@ref)).
- `profile`: the offer's [`FastStartProfile`](@ref) at the interval.
- `run1_mw`: the unit's energy target of the first run, MW, on its offer side's axis.
- `interval_minutes`: the interval length in minutes.

# Returns
A [`FastStartEndState`](@ref). Throws an `ArgumentError` for a `start_mode` outside 0 to 4.

# Example
```julia
profile = FastStartProfile((2.0, 3.0, 4.0, 5.0))
fast_start_end_state(0, 0.0, profile, 10.0)  # FastStartEndState(2, 3.0, nothing)
```
"""
function fast_start_end_state(
        start_mode::Integer, time_in_mode::Real, profile::FastStartProfile, run1_mw::Real;
        interval_minutes::Real = 5.0,
    )
    0 <= start_mode <= 4 || throw(ArgumentError("fast-start dispatch mode $start_mode is outside 0 to 4"))
    committed = start_mode == 0 && run1_mw > 0.0
    mode = committed ? 1 : Int(start_mode)
    elapsed = committed ? 0.0 : Float64(time_in_mode)
    left = Float64(interval_minutes)
    since = nothing
    for k in 1:3
        mode == k || continue
        remaining = fast_start_mode_length(profile, k) - elapsed
        remaining < left || continue
        left -= remaining
        mode = k + 1
        elapsed = 0.0
        k == 2 && (since = left)
    end
    end_time = mode == 0 ? 0.0 : elapsed + left
    mode == 4 && (end_time = min(end_time, profile.t4))
    return FastStartEndState(mode, end_time, since)
end


"""
    FastStartEnvelope(lower, upper, ramp, ramp_base, ramp_minutes)

The bounds a fast-start unit's energy target takes in NEMDE's dispatch run, from [`fast_start_envelope`](@ref),
on the offer side's axis, and the treatment of its energy ramp rows.

# Fields
- `lower`: the profile's lower bound on the target, MW.
- `upper`: the profile's upper bound on the target, MW, `Inf` where the profile sets none.
- `ramp`: `:none` when the unit has no energy ramp rows, `:from_minimum_load` when its ramp-up row starts at
  `ramp_base` and runs for `ramp_minutes` (its ramp-down row is unchanged), `:standard` when both rows are the
  unit's usual rows about its initial output.
- `ramp_base`: the minimum loading for `:from_minimum_load`, MW, `NaN` otherwise.
- `ramp_minutes`: the time since the end of mode 2 for `:from_minimum_load`, minutes, `NaN` otherwise.
"""
struct FastStartEnvelope
    lower::Float64
    upper::Float64
    ramp::Symbol
    ramp_base::Float64
    ramp_minutes::Float64
end


"""
    fast_start_envelope(end_state::FastStartEndState, profile::FastStartProfile, minimum_load) -> FastStartEnvelope

The profile bounds and ramp treatment of a fast-start unit in NEMDE's dispatch run, by its end mode, with `M` the
minimum loading and `t` the end time in mode: `0` in modes 0 and 1 (the upper bound binds; the lower bound is the
variable's own), `M t / T2` as a fixed target in mode 2, at least `M` in mode 3, and at least `M (1 - t / T4)` in
mode 4. A zero `T2` gives `M` in mode 2 and a zero `T4` gives `0` in mode 4. A unit ending in mode 0, 1 or 2 has
no energy ramp rows, a unit that left mode 2 during the interval ramps up from `M` over the time since, and any
other unit keeps its usual ramp rows.

# Arguments
- `end_state`: the unit's [`FastStartEndState`](@ref).
- `profile`: the offer's [`FastStartProfile`](@ref) at the interval.
- `minimum_load`: the offer's `MINIMUMLOAD`, MW.

# Returns
A [`FastStartEnvelope`](@ref).
"""
function fast_start_envelope(end_state::FastStartEndState, profile::FastStartProfile, minimum_load::Real)
    m = Float64(minimum_load)
    t = end_state.time_in_mode
    lower, upper = if end_state.mode <= 1
        (0.0, 0.0)
    elseif end_state.mode == 2
        target = profile.t2 > 0.0 ? m * t / profile.t2 : m
        (target, target)
    elseif end_state.mode == 3
        (m, Inf)
    else
        (profile.t4 > 0.0 ? m * (1.0 - t / profile.t4) : 0.0, Inf)
    end
    end_state.mode <= 2 && return FastStartEnvelope(lower, upper, :none, NaN, NaN)
    since = end_state.time_since_end_of_mode_two
    isnothing(since) && return FastStartEnvelope(lower, upper, :standard, NaN, NaN)
    return FastStartEnvelope(lower, upper, :from_minimum_load, m, since)
end


"""
    fast_start_ramp_up_limit(envelope::FastStartEnvelope, initial_mw, ramp_up_rate; interval_minutes = 5.0) -> Float64

The upper limit of a fast-start unit's ramp-up row in NEMDE's dispatch run: `Inf` without ramp rows,
`ramp_base + ramp_up_rate x ramp_minutes` for a unit that left mode 2 during the interval, and
`initial_mw + ramp_up_rate x interval_minutes` otherwise.

# Arguments
- `envelope`: the unit's [`FastStartEnvelope`](@ref).
- `initial_mw`: the unit's output at the start of the interval, MW.
- `ramp_up_rate`: the effective ramp-up rate, the lesser of the bid and telemetered rates, MW per minute.
- `interval_minutes`: the interval length in minutes.

# Returns
A `Float64` in MW.
"""
function fast_start_ramp_up_limit(
        envelope::FastStartEnvelope, initial_mw::Real, ramp_up_rate::Real; interval_minutes::Real = 5.0,
    )
    envelope.ramp == :none && return Inf
    envelope.ramp == :from_minimum_load && return envelope.ramp_base + ramp_up_rate * envelope.ramp_minutes
    return Float64(initial_mw + ramp_up_rate * interval_minutes)
end


"""
    fast_start_ramp_exempt(state::NEMUnitState, fast_start::Bool) -> Bool

Whether a unit's energy ramp rows are left out of NEMDE's commitment run: it is fast-start and starts the interval
in dispatch mode 0, 1 or 2. The same starting modes exempt it from the joint energy and regulation ramping limits
([`fcas_joint_ramping_exempt`](@ref)).

# Arguments
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.
- `fast_start`: whether the unit's offer is fast-start in the interval ([`is_fast_start`](@ref)).

# Returns
`Bool`.
"""
function fast_start_ramp_exempt(state::NEMUnitState, fast_start::Bool)
    return fast_start && state.dispatch_mode in (0, 1, 2)
end
