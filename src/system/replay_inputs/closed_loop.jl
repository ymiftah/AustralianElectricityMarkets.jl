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


"""
    ClosedLoopInputs

The state-independent inputs of one device's state-dependent replay inputs over the System's range, read once and
prepared per family on first use, so that a closed-loop step evaluates only the state-dependent rules.
Build with [`closed_loop_inputs`](@ref) and evaluate with [`closed_loop_input`](@ref).
"""
mutable struct ClosedLoopInputs
    device::PSY.Device
    base::Float64
    stamps::Vector{DateTime}
    resolution::Dates.Period
    index::Dict{DateTime, Int}
    observed::Union{Nothing, Vector{NEMUnitState}}
    ramp::Any
    fixed_load::Any
    fcas_window::Any
    fcas::Dict{BidType, Any}
end


"""
    closed_loop_inputs(device, base) -> ClosedLoopInputs

The [`ClosedLoopInputs`](@ref) of `device` over the range of its observed starting output series.

# Arguments
- `device`: a replay unit of a System built by `nem_system(db, NEMDEConfiguration(); date_range)`.
- `base`: the system base power, MVA.

# Returns
A [`ClosedLoopInputs`](@ref), its families prepared on first use.
"""
function closed_loop_inputs(device, base::Real)
    key = get_observed_state(device).initial_mw
    key isa IS.StaticTimeSeriesKey || throw(
        ArgumentError("\"$(PSY.get_name(device))\" has no observed starting output series; build the System with nem_system."),
    )
    ts = IS.get_time_series(device, key)
    stamps = collect(PSY.TimeSeries.timestamp(PSY.get_time_series_array(device, ts)))
    index = Dict(t => i for (i, t) in enumerate(stamps))
    return ClosedLoopInputs(device, Float64(base), stamps, IS.get_resolution(ts), index, nothing, nothing, nothing, nothing, Dict{BidType, Any}())
end


function _observed_states!(inputs::ClosedLoopInputs)
    isnothing(inputs.observed) && (inputs.observed = observed_unit_states(inputs.device, inputs.stamps))
    return inputs.observed
end


# The state of the device at interval `i` for `initial_mw` (MW), with its observed dispatch mode.
_closed_loop_state(inputs::ClosedLoopInputs, i::Int, initial_mw::Real) = NEMUnitState(Float64(initial_mw), _observed_states!(inputs)[i].dispatch_mode)


function _ramp_inputs!(inputs::ClosedLoopInputs)
    if isnothing(inputs.ramp)
        telemetry = _nem_unit_data(inputs.device).telemetry
        up = _bid_series(inputs.device, telemetry.ramp_up_limit, :ramp_up_limit)
        hours = Dates.value(Millisecond(up.resolution)) / 3_600_000
        inputs.ramp = _storage_ramp_inputs(inputs.device, up, hours)
    end
    return inputs.ramp
end


function _fixed_load_inputs!(inputs::ClosedLoopInputs)
    if isnothing(inputs.fixed_load)
        inputs.fixed_load = (;
            gen = _fixed_load_mw_series(inputs.device, OfferSide.GEN, inputs.stamps),
            load = _fixed_load_mw_series(inputs.device, OfferSide.LOAD, inputs.stamps),
        )
    end
    return inputs.fixed_load
end


# The prepared offer of the device in `bid_type`, `nothing` when it does not offer the market.
function _fcas_inputs!(inputs::ClosedLoopInputs, bid_type::BidType)
    return get!(inputs.fcas, bid_type) do
        direction = fcas_bid_direction(inputs.device, bid_type)
        direction == FCASBidDirection.NONE && return nothing
        if isnothing(inputs.fcas_window)
            inputs.fcas_window = _fcas_window(inputs.device, inputs.stamps, inputs.resolution, inputs.base; states = _observed_states!(inputs))
        end
        window = inputs.fcas_window
        _fcas_prepare(window, inputs.device, bid_type, direction, FCAS_INACTIVE_LIMIT_MW / inputs.base, _fcas_energy_limits(window, inputs.device))
    end
end


"""
    closed_loop_input(inputs::ClosedLoopInputs, series_name, t, initial_mw) -> Union{Nothing, Any}
    closed_loop_input(device, series_name, t, initial_mw, base) -> Union{Nothing, Any}

The value of the state-dependent replay input `series_name` of the device at the interval beginning at `t` when the
unit starts the interval at `initial_mw`, in the units and element type `nem_system` writes the series in. It
evaluates the writer's rules for that interval with the closed-loop state: `initial_mw` and the observed dispatch
mode, since fast-start profiles are not modelled.

# Arguments
- `inputs`: the device's [`ClosedLoopInputs`](@ref); the second form builds them for one call.
- `series_name`: the series name, see [`is_state_dependent_input`](@ref).
- `t`: the first timestamp of the interval.
- `initial_mw`: the unit's starting output, MW.

# Returns
The series value, or `nothing` when the series does not depend on the state for the device (a ramp rate of a
non-storage device, a series name that is not state-dependent, an FCAS market the device does not offer).
"""
function closed_loop_input(inputs::ClosedLoopInputs, series_name::AbstractString, t::DateTime, initial_mw::Real)
    family = _closed_loop_family(series_name)
    isnothing(family) && return nothing
    kind, arg = family
    device = inputs.device
    i = inputs.index[t]
    if kind == :ramp
        device isa PSY.Storage || return nothing
        up, down = _storage_ramp_at(_ramp_inputs!(inputs), i, initial_mw)
        value = arg == :up ? up : down
        return isnan(value) ? 0.0 : value / 60 / inputs.base
    end
    state = _closed_loop_state(inputs, i, initial_mw)
    if kind == :fixed_load
        fixed = _fixed_load_inputs!(inputs)
        step = _fixed_load_step_at(fixed.gen[i], fixed.load[i], state, device isa PSY.Storage)
        return arg == :target ? step.target / inputs.base : (step.invoked ? 1.0 : 0.0)
    end
    bid_type = kind == :fcas_offer ? first(arg) : arg
    prep = _fcas_inputs!(inputs, bid_type)
    isnothing(prep) && return nothing
    prep.window.states[i] = NEMUnitState(state.initial_mw / inputs.base, state.dispatch_mode)
    offers, ramping = _fcas_values_at(prep, device, bid_type, i)
    kind == :fcas_ramping && return ramping
    return get(offers, last(arg), nothing)
end

closed_loop_input(device, series_name::AbstractString, t::DateTime, initial_mw::Real, base::Real) =
    closed_loop_input(closed_loop_inputs(device, base), series_name, t, initial_mw)
