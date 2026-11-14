# The state-dependent replay inputs of one interval for a given starting output, computed by the same writer
# code that derives them from AEMO's observed state. A closed-loop replay reads them each step.

# The family of each state-dependent series name, `nothing` for the other series.
const _CLOSED_LOOP_FAMILIES = Dict{String, Tuple{Symbol, Any}}()

function _closed_loop_family(name::AbstractString)
    if isempty(_CLOSED_LOOP_FAMILIES)
        _CLOSED_LOOP_FAMILIES[NEM_SERIES.ramp_up_rate] = (:ramp, :up)
        _CLOSED_LOOP_FAMILIES[NEM_SERIES.ramp_down_rate] = (:ramp, :down)
        _CLOSED_LOOP_FAMILIES[NEM_STATE_INPUT_SERIES.fixed_load] = (:fixed_load, :target)
        _CLOSED_LOOP_FAMILIES[NEM_STATE_INPUT_SERIES.fixed_load_invoked] = (:fixed_load, :invoked)
        for bid_type in instances(BidType), decremental in (false, true)
            _CLOSED_LOOP_FAMILIES[fcas_effective_series_name(bid_type, decremental)] = (:fcas_offer, (bid_type, decremental))
            _CLOSED_LOOP_FAMILIES[fcas_ramping_series_name(bid_type)] = (:fcas_ramping, bid_type)
        end
    end
    return get(_CLOSED_LOOP_FAMILIES, name, nothing)
end


"""
    is_state_dependent_input(series_name) -> Bool

Whether the replay input series `series_name` is derived from the unit's starting state, so a closed-loop
replay recomputes it each interval with [`closed_loop_input`](@ref): the ramp rates (state-dependent for a
storage device), the fixed loading and its invocation, the effective FCAS offers and the regulation ramping
limits.

# Arguments
- `series_name`: the name of a replay input series.

# Returns
`Bool`.
"""
is_state_dependent_input(series_name::AbstractString) = !isnothing(_closed_loop_family(series_name))


"""
    closed_loop_unit_state(device, t, initial_mw) -> NEMUnitState

The state of `device` at the start of the interval beginning at `t` in a closed-loop replay: the starting
output `initial_mw`, in MW, with the observed dispatch mode at `t`, since fast-start profiles are not modelled.

# Arguments
- `device`: the NEM device.
- `t`: the first timestamp of the interval.
- `initial_mw`: the starting output, MW.

# Returns
A [`NEMUnitState`](@ref).
"""
function closed_loop_unit_state(device, t::DateTime, initial_mw::Real)
    observed = only(observed_unit_states(device, [t]))
    return NEMUnitState(Float64(initial_mw), observed.dispatch_mode)
end


# One stamp of a series-backed telemetry or bid field, shaped as `_bid_series` returns it.
function _bid_series_at(device, key, field::Symbol, t::DateTime)
    key isa IS.StaticTimeSeriesKey || return _bid_series(device, key, field)
    ts = IS.get_time_series(device, key)
    values = IS.get_time_series_values(device, key; start_time = t, len = 1)
    return (; timestamps = [t], resolution = IS.get_resolution(ts), values = Float64.(collect(values)))
end


# The effective offers and regulation ramping limits of `device` in `bid_type` at `t` for `state`, per-unit.
function _fcas_effective_at(device, bid_type::BidType, t::DateTime, base::Float64, state::NEMUnitState)
    direction = fcas_bid_direction(device, bid_type)
    direction == FCASBidDirection.NONE && return nothing, nothing
    window = _fcas_window(device, [t], DISPATCH_INTERVAL, base; states = [state])
    energy = _fcas_energy_limits(window, device)
    offers, ramping = _fcas_effective_values(window, device, bid_type, direction, FCAS_INACTIVE_LIMIT_MW / base, energy)
    return Dict(decremental => only(values) for (decremental, values) in offers), isnothing(ramping) ? nothing : only(ramping)
end


"""
    closed_loop_input(device, series_name, t, initial_mw, base) -> Union{Nothing, Any}

The value of the state-dependent replay input `series_name` of `device` at the interval beginning at `t`
when the unit starts the interval at `initial_mw`, in the units and element type `nem_system` writes the
series in. It runs the writer code of that series on the one interval with the closed-loop state of
[`closed_loop_unit_state`](@ref) in place of the observed state.

# Arguments
- `device`: the NEM device carrying the series.
- `series_name`: the series name, see [`is_state_dependent_input`](@ref).
- `t`: the first timestamp of the interval.
- `initial_mw`: the unit's starting output, MW.
- `base`: the system base power, MVA.

# Returns
The series value, or `nothing` when the series does not depend on the state for `device` (a ramp rate of a
non-storage device, a series name that is not state-dependent, an FCAS market the device does not offer).
"""
function closed_loop_input(device, series_name::AbstractString, t::DateTime, initial_mw::Real, base::Real)
    family = _closed_loop_family(series_name)
    isnothing(family) && return nothing
    kind, arg = family
    base = Float64(base)
    if kind == :ramp
        device isa PSY.Storage || return nothing
        telemetry = _nem_unit_data(device).telemetry
        up = _bid_series_at(device, telemetry.ramp_up_limit, :ramp_up_limit, t)
        down = _bid_series_at(device, telemetry.ramp_down_limit, :ramp_down_limit, t)
        ramp_up, ramp_down = _ramp_rate_values(device, up, down, base; initial = [Float64(initial_mw)])
        return arg == :up ? only(ramp_up) : only(ramp_down)
    end
    state = closed_loop_unit_state(device, t, initial_mw)
    if kind == :fixed_load
        step = only(_fixed_load_step_series(device, [t]; states = [state]))
        return arg == :target ? step.target / base : (step.invoked ? 1.0 : 0.0)
    end
    bid_type = kind == :fcas_offer ? first(arg) : arg
    offers, ramping = _fcas_effective_at(device, bid_type, t, base, state)
    kind == :fcas_ramping && return ramping
    return isnothing(offers) ? nothing : get(offers, last(arg), nothing)
end
