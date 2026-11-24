# The state-dependent NEMDE inputs of one interval for a given starting output, computed by the same writer
# code that derives them from AEMO's observed state. A closed-loop run reads them each step.

# The kind of a state-dependent series: `kind` is `:ramp` (`flag` set for the up rate), `:fixed_load` (`flag` set for the
# target, clear for the invocation), `:fcas_offer` (`flag` is `decremental`) or `:fcas_ramping`; `bid_type` is the FCAS market.
struct _ClosedLoopFamily
    kind::Symbol
    flag::Bool
    bid_type::BidType
end

# The family of each state-dependent series name; the other series have none.
function _closed_loop_families()
    none = first(instances(BidType))
    families = Dict{String, _ClosedLoopFamily}(
        NEM_SERIES.ramp_up_rate => _ClosedLoopFamily(:ramp, true, none),
        NEM_SERIES.ramp_down_rate => _ClosedLoopFamily(:ramp, false, none),
        NEM_STATE_INPUT_SERIES.fixed_load => _ClosedLoopFamily(:fixed_load, true, none),
        NEM_STATE_INPUT_SERIES.fixed_load_invoked => _ClosedLoopFamily(:fixed_load, false, none),
    )
    for bid_type in instances(BidType), decremental in (false, true)
        families[fcas_effective_series_name(bid_type, decremental)] = _ClosedLoopFamily(:fcas_offer, decremental, bid_type)
        families[fcas_ramping_series_name(bid_type)] = _ClosedLoopFamily(:fcas_ramping, false, bid_type)
    end
    return families
end

const _CLOSED_LOOP_FAMILIES = _closed_loop_families()

_closed_loop_family(name::AbstractString) = get(_CLOSED_LOOP_FAMILIES, name, nothing)


"""
    is_state_dependent_input(series_name) -> Bool

Whether the NEMDE input series `series_name` is derived from the unit's starting state, so a closed-loop
run recomputes it each interval with [`closed_loop_input`](@ref): the ramp rates (state-dependent for a
storage device), the fixed loading and its invocation, the effective FCAS offers and the regulation ramping
limits.

# Arguments
- `series_name`: the name of a NEMDE input series.

# Returns
`Bool`.
"""
is_state_dependent_input(series_name::AbstractString) = !isnothing(_closed_loop_family(series_name))


# The storage ramp inputs of one device over the System's range, as `_storage_ramp_at` reads them.
struct _ClosedLoopRamp
    minutes::Float64
    gen_up::Vector{Float64}
    gen_down::Vector{Float64}
    load_up::Vector{Float64}
    load_down::Vector{Float64}
    up::Vector{Float64}
    down::Vector{Float64}
end

function _ClosedLoopRamp(r)
    return _ClosedLoopRamp(
        Float64(r.minutes), Vector{Float64}(r.gen_up), Vector{Float64}(r.gen_down), Vector{Float64}(r.load_up),
        Vector{Float64}(r.load_down), Vector{Float64}(r.up), Vector{Float64}(r.down),
    )
end

# The fixed loading in MW of one device on each side over the System's range.
struct _ClosedLoopFixedLoad
    gen::Vector{Float64}
    load::Vector{Float64}
end


"""
    ClosedLoopInputs

The state-independent inputs of one device's state-dependent NEMDE inputs over the System's range,
prepared per family on first use. Build with [`closed_loop_inputs`](@ref) and evaluate with
[`closed_loop_input`](@ref).
"""
mutable struct ClosedLoopInputs
    device::PSY.Device
    base::Float64
    stamps::Vector{DateTime}
    resolution::Dates.Period
    index::Dict{DateTime, Int}
    observed::Union{Nothing, Vector{NEMUnitState}}
    ramp::Union{Nothing, _ClosedLoopRamp}
    fixed_load::Union{Nothing, _ClosedLoopFixedLoad}
    fcas_window::Union{Nothing, _FCASWindow}
    fcas::Dict{BidType, Union{Nothing, _FCASMarket}}
end


"""
    closed_loop_inputs(device, base) -> ClosedLoopInputs

The [`ClosedLoopInputs`](@ref) of `device` over the range of its observed starting output series.

# Arguments
- `device`: a NEMDE unit of a System built by `nem_system(db, NEMDEConfiguration(); date_range)`.
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
    return ClosedLoopInputs(
        device, Float64(base), stamps, IS.get_resolution(ts), index, nothing, nothing, nothing, nothing,
        Dict{BidType, Union{Nothing, _FCASMarket}}(),
    )
end


function _observed_states!(inputs::ClosedLoopInputs)
    isnothing(inputs.observed) && (inputs.observed = observed_unit_states(inputs.device, inputs.stamps))
    return inputs.observed
end


# The state of the device at interval `i` for `initial_mw` (MW), with its observed dispatch mode and time in mode.
function _closed_loop_state(inputs::ClosedLoopInputs, i::Int, initial_mw::Real)
    observed = _observed_states!(inputs)[i]
    return NEMUnitState(Float64(initial_mw), observed.dispatch_mode, observed.time_in_mode)
end


function _ramp_inputs!(inputs::ClosedLoopInputs)
    if isnothing(inputs.ramp)
        hours = Dates.value(Millisecond(inputs.resolution)) / 3_600_000
        inputs.ramp = _ClosedLoopRamp(_storage_ramp_inputs(inputs.device, inputs.stamps, hours))
    end
    return inputs.ramp
end


function _fixed_load_inputs!(inputs::ClosedLoopInputs)
    if isnothing(inputs.fixed_load)
        inputs.fixed_load = _ClosedLoopFixedLoad(
            _energy_bid_values(inputs.device, OfferSide.GEN, :fixed_load, inputs.stamps),
            _energy_bid_values(inputs.device, OfferSide.LOAD, :fixed_load, inputs.stamps),
        )
    end
    return inputs.fixed_load
end


# The market inputs of the device in `bid_type`, `nothing` when it does not offer the market.
function _fcas_inputs!(inputs::ClosedLoopInputs, bid_type::BidType)
    return get!(inputs.fcas, bid_type) do
        direction = fcas_bid_direction(inputs.device, bid_type)
        direction == FCASBidDirection.NONE && return nothing
        if isnothing(inputs.fcas_window)
            inputs.fcas_window = _fcas_window(inputs.device, inputs.stamps, inputs.resolution, inputs.base)
        end
        return _fcas_market(inputs.fcas_window, inputs.device, bid_type, direction)
    end
end


# The effective FCAS offers `(gen, load)` and regulation ramping limits of the device in `bid_type` at the interval
# beginning at `t` when it starts the interval at `initial_mw`, or `nothing` when it does not offer the market. One call
# serves both offer sides and the ramping limits of the market.
function _closed_loop_fcas_values(inputs::ClosedLoopInputs, bid_type::BidType, t::DateTime, initial_mw::Real)
    i = inputs.index[t]
    market = _fcas_inputs!(inputs, bid_type)
    isnothing(market) && return nothing
    state = _closed_loop_state(inputs, i, initial_mw)
    gen, load, ramping = _fcas_values_at(market, i, NEMUnitState(state.initial_mw / inputs.base, state.dispatch_mode, state.time_in_mode))
    return (gen, load), ramping
end


"""
    closed_loop_input(inputs::ClosedLoopInputs, series_name, t, initial_mw) -> Union{Nothing, Any}
    closed_loop_input(device, series_name, t, initial_mw, base) -> Union{Nothing, Any}

The value of the state-dependent NEMDE input `series_name` of the device at the interval beginning at `t` when the
unit starts the interval at `initial_mw`, in the units and element type `nem_system` writes the series in. It
evaluates the writer's rules for that interval with the closed-loop state: `initial_mw` and the observed dispatch
mode and time in mode.

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
    return _closed_loop_input(inputs, family, t, initial_mw)
end

# The value of the series of `family`; the FCAS families read `_closed_loop_fcas_values`.
function _closed_loop_input(inputs::ClosedLoopInputs, family::_ClosedLoopFamily, t::DateTime, initial_mw::Real)
    kind = family.kind
    device = inputs.device
    i = inputs.index[t]
    if kind == :ramp
        device isa PSY.Storage || return nothing
        up, down = _storage_ramp_at(_ramp_inputs!(inputs), i, initial_mw)
        value = family.flag ? up : down
        return isnan(value) ? 0.0 : value / 60 / inputs.base
    end
    if kind == :fixed_load
        state = _closed_loop_state(inputs, i, initial_mw)
        fixed = _fixed_load_inputs!(inputs)
        step = _fixed_load_step_at(fixed.gen[i], fixed.load[i], state, device isa PSY.Storage)
        return family.flag ? step.target / inputs.base : (step.invoked ? 1.0 : 0.0)
    end
    return _closed_loop_fcas_select(_closed_loop_fcas_values(inputs, family.bid_type, t, initial_mw), family)
end

# The series of an FCAS `family` from the values of its market: the ramping limits, or the offer of its side.
_closed_loop_fcas_select(::Nothing, ::_ClosedLoopFamily) = nothing
function _closed_loop_fcas_select(values, family::_ClosedLoopFamily)
    family.kind == :fcas_ramping && return values[2]
    return values[1][family.flag ? 2 : 1]
end

closed_loop_input(device, series_name::AbstractString, t::DateTime, initial_mw::Real, base::Real) =
    closed_loop_input(closed_loop_inputs(device, base), series_name, t, initial_mw)
