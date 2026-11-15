# NEMDE's two-run fast-start dispatch. The commitment run drops the energy ramp rows of fast-start units starting
# in mode 0, 1 or 2; the dispatch run holds them to their inflexibility profile, from the commitment run's targets.
# Every rule is AEM's kernel (`fast_start_end_state`, `fast_start_envelope`); this file only sets the rows.

#! format: off
PSI.get_multiplier_value(::FastStartModeTimeSeriesParameter, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 1.0

PSI.get_parameter_multiplier(::PSI.FixValueParameter, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 1.0
#! format: on


# The right-hand side `value` in system-base per-unit, with an infinite one, which a model export cannot write,
# replaced by `FCAS_INACTIVE_LIMIT_MW` of the same sign, a bound no unit's row reaches.
_rhs(value::Real, base::Real) = isinf(value) ? copysign(FCAS_INACTIVE_LIMIT_MW / base, value) : Float64(value)

# The fast-start run of a model, from its `"fast_start_run"` setting; `nothing` for a single run.
function _fast_start_run(container::PSI.OptimizationContainer)
    return get(PSI.get_ext(PSI.get_settings(container)), "fast_start_run", nothing)::Union{Nothing, String}
end


# The fast-start units of one device type in a fast-start run, with the normalized right-hand sides their
# standard ramp rows were built with, indexed `[unit, t]`.
struct _FastStartRows{T}
    run::String
    devices::Vector{T}
    ramp_up::Matrix{Float64}
    ramp_down::Matrix{Float64}
end

function _fast_start_rows(container::PSI.OptimizationContainer, ::Type{T}) where {T}
    return get(_build_scratch(container), (_FastStartRows, T), nothing)
end

# The meta PowerSimulations gives the `FixValueParameter` carrying a variable, computed as PowerSimulations does.
_fix_value_meta(::Type{V}) where {V <: PSI.VariableType} = "$V"


"""
    _add_fast_start_rows!(container, devices, model::PSI.DeviceModel{T})

Adds the fast-start rows of the units of `devices` with a fast-start profile (`has_fast_start_profile`) in a
fast-start run, and nothing in a single run or for a battery. Both runs add a
[`FastStartModeTimeSeriesParameter`](@ref), whose per-step update resets the rows. The dispatch run also adds the
`"fast_start|lower"`, `"fast_start|upper"` and `"fast_start|ramp_up"` rows of [`NEMUnitConstraint`](@ref), the
first two with [`NEMUnitSlack`](@ref) slacks priced at `FAST_START_CVP_FACTOR` times the Market Price Cap and the
third sharing the unit's `"unit_ramp|up"` slack. The rows are then set for the build's initial time
([`_set_fast_start_rows!`](@ref)).

# Returns
`nothing`.
"""
function _add_fast_start_rows!(container::PSI.OptimizationContainer, devices, model::PSI.DeviceModel{T}) where {T <: PSY.StaticInjection}
    run = _fast_start_run(container)
    (isnothing(run) || T <: PSY.Storage) && return
    fast = T[d for d in devices if has_fast_start_profile(d)]
    isempty(fast) && return
    PSI.add_parameters!(
        container, FastStartModeTimeSeriesParameter, fast, model; time_series_name = NEM_FAST_START_SERIES.start_mode,
    )
    names = PSY.get_name.(fast)
    time_steps = PSI.get_time_steps(container)
    standard(meta) = begin
        rows = PSI.get_constraint(container, PSI.RampConstraint(), T, meta)
        return Float64[JuMP.normalized_rhs(rows[name, t]) for name in names, t in time_steps]
    end
    run == "dispatch" && _add_fast_start_profile_rows!(container, T, names, time_steps)
    _build_scratch(container)[(_FastStartRows, T)] = _FastStartRows{T}(run, fast, standard("up"), standard("dn"))
    _set_fast_start_rows!(container, T, PSI.get_initial_time(container))
    return
end

# The dispatch run's profile and ramp-up rows of `names`, built with placeholder bounds that `_set_fast_start_rows!` sets.
function _add_fast_start_profile_rows!(container::PSI.OptimizationContainer, ::Type{T}, names, time_steps) where {T}
    jump_model = PSI.get_jump_model(container)
    power = PSI.get_variable(container, PSI.ActivePowerVariable(), T)
    slack(variant) = _add_cvp_slack!(
        container, NEMUnitSlack, T, names, time_steps, _nem_unit_slack_cvp(variant);
        meta = _nem_unit_slack_meta(variant), label = _nem_unit_slack_label(variant),
    )
    below, above = slack(FastStartLowerVariant()), slack(FastStartUpperVariant())
    ramp_slack = PSI.get_variable(container, NEMUnitSlack(), T, _nem_unit_slack_meta(UnitRampUpVariant()))
    rows(meta) = PSI.add_constraints_container!(container, NEMUnitConstraint(), T, names, time_steps; meta)
    lower, upper, ramp_up = rows("fast_start|lower"), rows("fast_start|upper"), rows("fast_start|ramp_up")
    for name in names, t in time_steps
        lower[name, t] = JuMP.@constraint(jump_model, power[name, t] + below[name, t] >= 0.0)
        upper[name, t] = JuMP.@constraint(jump_model, power[name, t] - above[name, t] <= 0.0)
        ramp_up[name, t] = JuMP.@constraint(jump_model, power[name, t] - ramp_slack[name, t] <= 0.0)
    end
    return
end

# The commitment run's energy target of each unit, per-unit, from the dispatch run's `FixValueParameter`. A standalone
# dispatch run has none and reads 0; a sequence's dispatch run must have the feedforward that adds it.
function _commitment_targets(container::PSI.OptimizationContainer, ::Type{T}) where {T}
    meta = _fix_value_meta(PSI.ActivePowerVariable)
    if !PSI.has_container_key(container, PSI.FixValueParameter, T, meta)
        sequenced = get(PSI.get_ext(PSI.get_settings(container)), "fast_start_feedforward", false)::Bool
        sequenced && throw(
            ArgumentError(
                "fast-start dispatch run of nem_dispatch_sequence: no commitment target for $T " *
                    "(FixValueParameter with meta \"$meta\"); the feedforward is missing",
            ),
        )
        return (name, t) -> 0.0
    end
    values = PSI.get_parameter_array(container, PSI.FixValueParameter(), T, meta)
    return (name, t) -> Float64(values[name, t])
end


"""
    _set_fast_start_rows!(container, T, start_time::DateTime)

Sets the fast-start rows of the units of type `T` for the window from `start_time`, from AEM's
`fast_start_unit_inputs`. In the commitment run, a unit exempt by `fast_start_ramp_exempt` (fast-start and starting
in mode 0, 1 or 2) has its energy ramp rows relaxed. In the dispatch run, the unit's end state
(`fast_start_end_state`) of the commitment run's target gives its `fast_start_envelope`: the profile rows take the
envelope's bounds, both ramp rows are relaxed for `:none`, the ramp-up row is replaced by the `"fast_start|ramp_up"`
row at `fast_start_ramp_up_limit` for `:from_minimum_load`, and both keep their built bounds for `:standard`. A unit
that is not fast-start at an interval keeps its ramp rows and has its profile rows relaxed.

# Returns
`nothing`.
"""
function _set_fast_start_rows!(container::PSI.OptimizationContainer, ::Type{T}, start_time::DateTime) where {T}
    rows = _fast_start_rows(container, T)
    isnothing(rows) && return
    rows = rows::_FastStartRows{T}
    time_steps = PSI.get_time_steps(container)
    base = PSI.get_base_power(container)
    minutes = 60 * interval_hours(PSI.get_resolution(container))
    con_up = PSI.get_constraint(container, PSI.RampConstraint(), T, "up")
    con_dn = PSI.get_constraint(container, PSI.RampConstraint(), T, "dn")
    dispatch = rows.run == "dispatch"
    if dispatch
        lower = PSI.get_constraint(container, NEMUnitConstraint(), T, "fast_start|lower")
        upper = PSI.get_constraint(container, NEMUnitConstraint(), T, "fast_start|upper")
        ramp_up = PSI.get_constraint(container, NEMUnitConstraint(), T, "fast_start|ramp_up")
        target = _commitment_targets(container, T)
    end
    for (i, device) in enumerate(rows.devices)
        name = PSY.get_name(device)
        inputs = fast_start_unit_inputs(device, start_time, length(time_steps))
        for t in time_steps
            unit = inputs[t]
            ramp = if !dispatch
                # The exemption reads the starting mode only; the initial output is not used.
                fast_start_ramp_exempt(NEMUnitState(NaN, unit.start_mode, unit.time_in_mode), unit.fast_start) ? :none : :standard
            elseif !unit.fast_start
                JuMP.set_normalized_rhs(lower[name, t], _rhs(-Inf, base))
                JuMP.set_normalized_rhs(upper[name, t], _rhs(Inf, base))
                JuMP.set_normalized_rhs(ramp_up[name, t], _rhs(Inf, base))
                :standard
            else
                end_state = fast_start_end_state(
                    unit.start_mode, unit.time_in_mode, unit.profile, target(name, t) * base; interval_minutes = minutes,
                )
                envelope = fast_start_envelope(end_state, unit.profile, unit.minimum_load)
                JuMP.set_normalized_rhs(lower[name, t], _rhs(envelope.lower / base, base))
                JuMP.set_normalized_rhs(upper[name, t], _rhs(envelope.upper / base, base))
                limit = envelope.ramp == :from_minimum_load ?
                    fast_start_ramp_up_limit(envelope, NaN, _ramp_up_rate(device, start_time, t) * base; interval_minutes = minutes) :
                    Inf
                JuMP.set_normalized_rhs(ramp_up[name, t], _rhs(limit / base, base))
                envelope.ramp
            end
            JuMP.set_normalized_rhs(con_up[name, t], _rhs(ramp == :standard ? rows.ramp_up[i, t] : Inf, base))
            JuMP.set_normalized_rhs(con_dn[name, t], _rhs(ramp == :none ? Inf : rows.ramp_down[i, t], base))
        end
    end
    return
end

# The effective ramp-up rate of `device` at step `t` of the window from `start_time`, system-base per-unit per minute.
function _ramp_up_rate(device, start_time::DateTime, t::Integer)
    values = PSY.get_time_series_values(
        PSY.SingleTimeSeries, device, NEM_SERIES.ramp_up_rate; start_time, len = t, ignore_scaling_factors = true,
    )
    return Float64(values[t])
end


"""
    PSI.add_feedforward_constraints!(container, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, devices, ff::PSI.FixValueFeedforward)

Adds nothing for the feedforward of [`nem_dispatch_sequence`](@ref), whose affected value is
[`FastStartCommitmentTargetParameter`](@ref), and PowerSimulations' fixing rows for any other `FixValueFeedforward`.

# Returns
`nothing`.
"""
function PSI.add_feedforward_constraints!(
        container::PSI.OptimizationContainer, model::PSI.DeviceModel{T, <:AbstractNEMDispatch},
        devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}}, ff::PSI.FixValueFeedforward,
    ) where {T <: PSY.StaticInjection}
    _is_commitment_target(ff) && return
    @invoke PSI.add_feedforward_constraints!(
        container::PSI.OptimizationContainer, model::PSI.DeviceModel, devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}},
        ff::PSI.FixValueFeedforward,
    )
    return
end

_is_commitment_target(ff::PSI.FixValueFeedforward) =
    all(k -> IS.Optimization.get_entry_type(k) === FastStartCommitmentTargetParameter, PSI.get_affected_values(ff))


# --- Per-step updates -------------------------------------------------------------------------------

# Reads the commitment run's targets of the simulation state into the dispatch run's `FixValueParameter`.
function _read_commitment_targets!(model::PSI.DecisionModel, key::PSI.ParameterKey{PSI.FixValueParameter, T}, state::PSI.SimulationState) where {T}
    param_container = PSI.get_parameter(PSI.get_optimization_container(model), key)
    PSI._update_parameter_values!(
        PSI.get_parameter_array(param_container), PSI.FixValueParameter(), PSI.get_attributes(param_container), T, model,
        PSI.get_decision_states(state),
    )
    return param_container
end

"""
    PSI.update_parameter_values!(model::PSI.DecisionModel{<:AbstractNEMDispatchProblem}, key::PSI.ParameterKey{PSI.FixValueParameter, T}, state)

Reads the commitment run's energy targets of the simulation state into the dispatch run's `FixValueParameter`. The
parameter fixes no variable; [`_set_fast_start_rows!`](@ref) reads it.

# Returns
`nothing`.
"""
function PSI.update_parameter_values!(
        model::PSI.DecisionModel{<:AbstractNEMDispatchProblem}, key::PSI.ParameterKey{PSI.FixValueParameter, T},
        state::PSI.SimulationState,
    ) where {T <: PSY.StaticInjection}
    param_container = _read_commitment_targets!(model, key, state)
    PSI.IS.@record :execution PSI.ParameterUpdateEvent(
        PSI.FixValueParameter, T, PSI.get_attributes(param_container), PSI.get_current_timestamp(model), PSI.get_name(model),
    )
    return
end

"""
    PSI.update_parameter_values!(model::PSI.DecisionModel{<:AbstractNEMDispatchProblem}, key::PSI.ParameterKey{FastStartModeTimeSeriesParameter, T}, state)

Updates the starting fast-start mode of the interval with PowerSimulations' own update, then sets the fast-start
rows of `T` for the interval ([`_set_fast_start_rows!`](@ref)), reading the commitment run's targets first in the
dispatch run.

# Returns
`nothing`.
"""
function PSI.update_parameter_values!(
        model::PSI.DecisionModel{<:AbstractNEMDispatchProblem}, key::PSI.ParameterKey{FastStartModeTimeSeriesParameter, T},
        state::PSI.SimulationState,
    ) where {T <: PSY.StaticInjection}
    _update_fast_start_rows!(model, key, state)
    return
end

# The closed-loop method, which the closed-loop time-series update would otherwise make ambiguous.
function PSI.update_parameter_values!(
        model::PSI.DecisionModel{NEMClosedLoopDispatchProblem}, key::PSI.ParameterKey{FastStartModeTimeSeriesParameter, T},
        state::PSI.SimulationState,
    ) where {T <: PSY.StaticInjection}
    _update_fast_start_rows!(model, key, state)
    return
end

function _update_fast_start_rows!(model, key::PSI.ParameterKey{P, T}, state::PSI.SimulationState) where {P, T}
    @invoke PSI.update_parameter_values!(model::PSI.OperationModel, key::PSI.ParameterKey{P, T}, state::PSI.SimulationState)
    container = PSI.get_optimization_container(model)
    meta = _fix_value_meta(PSI.ActivePowerVariable)
    # The targets are read here too, so the rows never depend on the order PowerSimulations updates parameters in.
    PSI.has_container_key(container, PSI.FixValueParameter, T, meta) &&
        _read_commitment_targets!(model, PSI.ParameterKey(PSI.FixValueParameter, T, meta), state)
    _set_fast_start_rows!(container, T, PSI.get_current_time(model))
    return
end
