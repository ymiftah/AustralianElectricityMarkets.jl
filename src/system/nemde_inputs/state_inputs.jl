# The observed starting state of each NEMDE unit and its fixed loading, read per interval.


"""
    _has_fixed_load_bid(device) -> Bool

Whether `device` has an energy bid carrying a fixed loading on either side.

# Arguments
- `device`: the NEM device.

# Returns
`Bool`.
"""
function _has_fixed_load_bid(device)
    cost = _nem_offer_cost(device)
    isnothing(cost) && return false
    return any(b -> !isnothing(b.fixed_load), get_energy_bids(cost))
end


# Whether the build observes no dispatched state for `device` at each of `stamps`: the stamp is outside
# the device's registration span, where AEMO publishes no DISPATCHLOAD row, or the device is a pinned
# non-scheduled load. A device without a registration is always observed.
function _unobserved_stamp_mask(device, stamps::AbstractVector{DateTime})
    n = length(stamps)
    is_non_scheduled_load(device) && return fill(true, n)
    unit = _nem_unit_data(device)
    registration = isnothing(unit) ? nothing : unit.registration
    isnothing(registration) && return fill(false, n)
    return [!_is_registered(registration, t) for t in stamps]
end


"""
    observed_unit_states(device, stamps::AbstractVector{DateTime}) -> Vector{NEMUnitState}

The state of `device` at the start of the interval beginning at each stamp of `stamps`, read from its
[`NEMObservedState`](@ref). A stamp with a finite dispatch mode gives its observed output and mode, and the
time in mode of [`fast_start_time_in_mode`](@ref) from the observed mode time and the fast-start profile of the
device's energy offer at the stamp. A stamp with a non-finite mode gives zero output in mode `0` when the build
does not observe the unit there (outside the device's registration, or a pinned non-scheduled load), and the
observed output in mode `0` when the previous interval is unobserved, which is the device's first registered
interval. The time in mode is zero in mode `0`.

# Arguments
- `device`: the NEM device.
- `stamps`: the first timestamps of the intervals, consecutive at the series' resolution.

# Returns
A `Vector{NEMUnitState}` the length of `stamps`. Throws an `ArgumentError` naming `device` and the stamp
when `device` has no NEM observed state, when the dispatch mode is not finite at a stamp whose previous
interval is observed, or when the mode time of a fast-start unit in modes 1 to 4 is not finite.
"""
function observed_unit_states(device, stamps::AbstractVector{DateTime})::Vector{NEMUnitState}
    observed = get_observed_state(device)
    initial = _values_on_grid(device, observed.initial_mw, stamps)
    mode = _values_on_grid(device, observed.dispatch_mode, stamps)
    mode_time = _values_on_grid(device, observed.dispatch_mode_time, stamps)
    profiles = _fast_start_profile_window(device, stamps)
    unobserved = _unobserved_stamp_mask(device, stamps)
    previous = _unobserved_stamp_mask(device, stamps .- Minute(5))
    states = Vector{NEMUnitState}(undef, length(stamps))
    for i in eachindex(stamps)
        if isfinite(mode[i])
            m = Int(mode[i])
            time = fast_start_time_in_mode(m, mode_time[i], profiles[i])
            isfinite(time) || throw(
                ArgumentError(
                    "The dispatch mode time of \"$(PSY.get_name(device))\" at $(stamps[i]) is not finite in mode $m. " *
                        "Check that DISPATCHLOAD publishes DISPATCHMODETIME at the previous interval (t - 5 minutes).",
                ),
            )
            states[i] = NEMUnitState(initial[i], m, time)
        elseif unobserved[i]
            states[i] = NEMUnitState(0.0, 0)
        elseif previous[i]
            states[i] = NEMUnitState(initial[i], 0)
        else
            t = stamps[i]
            throw(
                ArgumentError(
                    "The dispatch mode of \"$(PSY.get_name(device))\" at $(t) is not finite. " *
                        "Check that the unit has a DISPATCHLOAD row at the previous interval (t - 5 minutes), " *
                        "which holds its dispatch mode.",
                ),
            )
        end
    end
    return states
end


# The starting output in MW at each of `stamps`, zero where the build does not observe the unit. It needs
# only the output, so a stamp with a non-finite dispatch mode still gives its observed output.
function _initial_mw_series(device, stamps::AbstractVector{DateTime})
    initial = _values_on_grid(device, get_observed_state(device).initial_mw, stamps)
    unobserved = _unobserved_stamp_mask(device, stamps)
    return [unobserved[i] ? 0.0 : initial[i] for i in eachindex(stamps)]
end


"""
    _fixed_load_step_series(device, stamps::AbstractVector{DateTime}) -> Vector{NamedTuple}

The fixed-loading target and invocation of `device` at each of `stamps`, as `(; target, invoked)`. The
target is on the net-injection axis in MW: the generation side's loading plus the load side's, with a
storage device's load side negated. A side applies only when [`fixed_load_invoked`](@ref) holds for its
loading and the unit's [`observed_unit_states`](@ref) state.

# Arguments
- `device`: the NEM device.
- `stamps`: the first timestamps of the intervals, consecutive at the series' resolution.

# Returns
A `Vector` the length of `stamps` of `(; target, invoked)` named tuples, `target` in MW and `invoked` a `Bool`.
"""
function _fixed_load_step_series(device, stamps::AbstractVector{DateTime})
    states = observed_unit_states(device, stamps)
    gens = _energy_bid_values(device, OfferSide.GEN, :fixed_load, stamps)
    loads = _energy_bid_values(device, OfferSide.LOAD, :fixed_load, stamps)
    storage = device isa PSY.Storage
    return _fixed_load_step_at.(gens, loads, states, storage)
end


# The fixed-loading target (MW, net injection axis) and invocation of one interval from each side's raw loading.
function _fixed_load_step_at(gen::Real, load::Real, state::NEMUnitState, storage::Bool)
    target = if storage
        effective_fixed_load(gen, state) - effective_fixed_load(load, state)
    else
        effective_fixed_load(gen, state) + effective_fixed_load(load, state)
    end
    return (; target, invoked = fixed_load_invoked(gen, state) || fixed_load_invoked(load, state))
end


"""
    _set_observed_state_inputs!(sys::PSY.System, grid = _nemde_grid(sys)) -> Nothing

Adds, for each NEM dispatch device of `sys` whose observed starting output is a time series, the series
named by [`NEM_STATE_INPUT_SERIES`](@ref) on `grid`: `initial_mw` in MW, zero where
the build does not observe the unit. A device whose energy bid carries a fixed loading also gets
`fixed_load`, the target in system-base per-unit, and `fixed_load_invoked`, `1` or `0`, from
[`_fixed_load_step_series`](@ref). A device with a static starting output gets none of them.

# Arguments
- `sys`: the system whose observed state [`nem_system`](@ref) attached.
- `grid`: the timestamps the single time series of `sys` share; read from `sys` by default.

# Returns
`nothing`.
"""
function _set_observed_state_inputs!(sys::PSY.System, grid = _nemde_grid(sys))
    base = PSY.get_base_power(sys)
    _foreach_nem_dispatch_device(sys) do device
        observed = get_observed_state(device)
        observed.initial_mw isa IS.StaticTimeSeriesKey || return
        initial = _initial_mw_series(device, grid)
        PSY.add_time_series!(sys, device, single_series(NEM_STATE_INPUT_SERIES.initial_mw, first(grid), initial, step(grid)))
        _has_fixed_load_bid(device) || return
        steps = _fixed_load_step_series(device, grid)
        fixed = [step.target / base for step in steps]
        invoked = [step.invoked ? 1.0 : 0.0 for step in steps]
        PSY.add_time_series!(sys, device, single_series(NEM_STATE_INPUT_SERIES.fixed_load, first(grid), fixed, step(grid)))
        PSY.add_time_series!(sys, device, single_series(NEM_STATE_INPUT_SERIES.fixed_load_invoked, first(grid), invoked, step(grid)))
        return
    end
    return
end
