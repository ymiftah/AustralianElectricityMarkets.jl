# The observed starting state of each replay unit and its fixed loading, read per interval.


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


# The values of one field of `device`'s observed state over `stamps`, as Float64: a static value is repeated.
function _observed_grid(device, field::Symbol, stamps::AbstractVector{DateTime})
    value = getproperty(get_observed_state(device), field)
    value isa IS.StaticTimeSeriesKey || return fill(Float64(value), length(stamps))
    return Float64.(IS.get_time_series_values(device, value; start_time = first(stamps), len = length(stamps)))
end


"""
    observed_unit_states(device, stamps::AbstractVector{DateTime}) -> Vector{NEMUnitState}

The state of `device` at the start of the interval beginning at each stamp of `stamps`, read from its
[`NEMObservedState`](@ref). A stamp with a finite dispatch mode gives its observed output and mode. A stamp
with a non-finite mode gives zero output in mode `0` when the build does not observe the unit there (outside
the device's registration, or a pinned non-scheduled load), and the observed output in mode `0` when the
previous interval is unobserved, which is the device's first registered interval.

# Arguments
- `device`: the NEM device.
- `stamps`: the first timestamps of the intervals, consecutive at the series' resolution.

# Returns
A `Vector{NEMUnitState}` the length of `stamps`. Throws an `ArgumentError` naming `device` and the stamp
when `device` has no NEM observed state, or when the dispatch mode is not finite at a stamp whose previous
interval is observed.
"""
function observed_unit_states(device, stamps::AbstractVector{DateTime})::Vector{NEMUnitState}
    initial = _observed_grid(device, :initial_mw, stamps)
    mode = _observed_grid(device, :dispatch_mode, stamps)
    unobserved = _unobserved_stamp_mask(device, stamps)
    previous = _unobserved_stamp_mask(device, stamps .- Minute(5))
    states = Vector{NEMUnitState}(undef, length(stamps))
    for i in eachindex(stamps)
        if isfinite(mode[i])
            states[i] = NEMUnitState(initial[i], Int(mode[i]))
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
    initial = _observed_grid(device, :initial_mw, stamps)
    unobserved = _unobserved_stamp_mask(device, stamps)
    return [unobserved[i] ? 0.0 : initial[i] for i in eachindex(stamps)]
end


# The raw `FIXEDLOAD` of `device`'s `side` energy bid at each of `stamps`, MW; `NaN` where the bid has none.
function _fixed_load_mw_series(device, side::OfferSide, stamps::AbstractVector{DateTime})
    cost = _nem_offer_cost(device)
    bid = isnothing(cost) ? nothing : _energy_bid(cost, side)
    isnothing(bid) && return fill(NaN, length(stamps))
    value = bid.fixed_load
    value isa IS.StaticTimeSeriesKey || return fill(isnothing(value) ? NaN : Float64(value), length(stamps))
    return Float64.(IS.get_time_series_values(device, value; start_time = first(stamps), len = length(stamps)))
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
    gens = _fixed_load_mw_series(device, OfferSide.GEN, stamps)
    loads = _fixed_load_mw_series(device, OfferSide.LOAD, stamps)
    states = observed_unit_states(device, stamps)
    storage = device isa PSY.Storage
    return map(eachindex(stamps)) do i
        state = states[i]
        gen, load = gens[i], loads[i]
        target = if storage
            effective_fixed_load(gen, state) - effective_fixed_load(load, state)
        else
            effective_fixed_load(gen, state) + effective_fixed_load(load, state)
        end
        return (; target, invoked = fixed_load_invoked(gen, state) || fixed_load_invoked(load, state))
    end
end


"""
    _set_observed_state_inputs!(sys::PSY.System) -> Nothing

Adds, for each NEM dispatch device of `sys` whose observed starting output is a time series, the series
named by [`NEM_STATE_INPUT_SERIES`](@ref) on the timestamps of that output: `initial_mw` in MW, zero where
the build does not observe the unit. A device whose energy bid carries a fixed loading also gets
`fixed_load`, the target in system-base per-unit, and `fixed_load_invoked`, `1` or `0`, from
[`_fixed_load_step_series`](@ref). A device with a static starting output, or with no observed state, gets none of them.

# Arguments
- `sys`: the system whose observed state [`nem_system`](@ref) attached.

# Returns
`nothing`.
"""
function _set_observed_state_inputs!(sys::PSY.System)
    base = PSY.get_base_power(sys)
    _foreach_nem_dispatch_device(sys) do device
        observed = _nem_unit_data(device).observed_state
        isnothing(observed) && return
        observed.initial_mw isa IS.StaticTimeSeriesKey || return
        name = PSY.get_name(observed.initial_mw)
        stamps = PSY.get_time_series_timestamps(PSY.SingleTimeSeries, device, name)
        resolution = IS.get_resolution(PSY.get_time_series(PSY.SingleTimeSeries, device, name))
        initial = _initial_mw_series(device, stamps)
        PSY.add_time_series!(sys, device, single_series(NEM_STATE_INPUT_SERIES.initial_mw, first(stamps), initial, resolution))
        _has_fixed_load_bid(device) || return
        steps = _fixed_load_step_series(device, stamps)
        fixed = [step.target / base for step in steps]
        invoked = [step.invoked ? 1.0 : 0.0 for step in steps]
        PSY.add_time_series!(sys, device, single_series(NEM_STATE_INPUT_SERIES.fixed_load, first(stamps), fixed, resolution))
        PSY.add_time_series!(sys, device, single_series(NEM_STATE_INPUT_SERIES.fixed_load_invoked, first(stamps), invoked, resolution))
        return
    end
    return
end
