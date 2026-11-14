# Closed-loop replay: each interval starts from the previous interval's solved state. The starting output of
# each unit and the starting flow of each MNSP are PowerSimulations initial conditions; the inputs derived from
# that state are recomputed each step with AEM's writer code (`closed_loop_input`).

# The series value of the starting output at the build's initial time, as stored (MW).
function _initial_series_value(device, name::AbstractString, initial_time::DateTime)
    return Float64(only(PSY.get_time_series_values(PSY.SingleTimeSeries, device, name; start_time = initial_time, len = 1)))
end

# An initial condition of `component` with starting value `value`: a fixed JuMP parameter in a recurrent
# build, a constant otherwise.
function _closed_loop_ic(container, ::Type{D}, component, value::Float64) where {D <: PSI.InitialConditionType}
    PSI.built_for_recurrent_solves(container) || return PSI.InitialCondition{D, Float64}(component, value)
    return PSI.InitialCondition{D, JuMP.VariableRef}(component, PSI.add_jump_parameter(PSI.get_jump_model(container), value))
end

"""
    _add_initial_power!(container, devices, model)

Adds the starting output of each of `devices`: the [`InitialPowerTimeSeriesParameter`](@ref) of its observed
starting output in an open-loop replay, and a [`NEMInitialPower`](@ref) initial condition seeded with the
observed output at the build's initial time in a closed-loop replay.

# Returns
`nothing`.
"""
function _add_initial_power!(container::PSI.OptimizationContainer, devices, model::PSI.DeviceModel{T}) where {T}
    if !_closed_loop(container)
        PSI.add_parameters!(container, InitialPowerTimeSeriesParameter, devices, model; time_series_name = NEM_STATE_INPUT_SERIES.initial_mw)
        return
    end
    seeded = [d for d in devices if PSY.has_time_series(d, PSY.SingleTimeSeries, NEM_STATE_INPUT_SERIES.initial_mw)]
    isempty(seeded) && return
    t0 = PSI.get_initial_time(container)
    base = PSI.get_base_power(container)
    ics = PSI.add_initial_condition_container!(container, NEMInitialPower(), T, seeded)
    for (i, d) in enumerate(seeded)
        ics[i] = _closed_loop_ic(container, NEMInitialPower, d, _initial_series_value(d, NEM_STATE_INPUT_SERIES.initial_mw, t0) / base)
    end
    return
end

"""
    _add_initial_flow!(container, mnsp)

Adds a [`NEMInitialFlow`](@ref) initial condition for each MNSP of `mnsp`, seeded with its metered flow at the
build's initial time, in MW.

# Returns
`nothing`.
"""
function _add_initial_flow!(container::PSI.OptimizationContainer, mnsp)
    isempty(mnsp) && return
    t0 = PSI.get_initial_time(container)
    ics = PSI.add_initial_condition_container!(container, NEMInitialFlow(), PSY.AreaInterchange, mnsp)
    for (i, d) in enumerate(mnsp)
        ics[i] = _closed_loop_ic(container, NEMInitialFlow, d, _initial_series_value(d, NEM_MNSP_SERIES.initial_flow, t0))
    end
    return
end

# The values of the `D` initial conditions of component type `T`, by component name, as `JuMP.AffExpr`.
function _ic_values(container, ::Type{D}, ::Type{T}) where {D <: PSI.InitialConditionType, T}
    PSI.has_container_key(container, D, T) || return Dict{String, JuMP.AffExpr}()
    ics = PSI.get_initial_condition(container, D(), T)
    return Dict{String, JuMP.AffExpr}(PSY.get_name(PSI.get_component(ic)) => convert(JuMP.AffExpr, PSI.get_value(ic)) for ic in ics)
end

# The closed-loop branch of `_initial_mw_accessor`: the `NEMInitialPower` initial conditions, per-unit.
function _closed_loop_initial_mw(container, ::Type{T}) where {T}
    values = _ic_values(container, NEMInitialPower, T)
    accessor(name, t) = values[name]
    return accessor, Set(keys(values))
end

# The closed-loop branch of `_mnsp_initial_flow_accessor`: the `NEMInitialFlow` initial conditions, MW.
function _closed_loop_initial_flow(container)
    values = _ic_values(container, NEMInitialFlow, PSY.AreaInterchange)
    accessor(name, t) = values[name]
    return accessor
end

# --- State carried between steps ---------------------------------------------------------------------

# The solved output of each component of type `T` at the last solved interval, per-unit, by name: the net of
# discharge and charge for a battery.
function _solved_output(state::PSI.SimulationState, ::Type{T}) where {T <: PSY.Storage}
    out = PSI.get_system_state_value(state, PSI.ActivePowerOutVariable(), T)
    in_ = PSI.get_system_state_value(state, PSI.ActivePowerInVariable(), T)
    return name -> out[name] - in_[name]
end
function _solved_output(state::PSI.SimulationState, ::Type{T}) where {T <: PSY.Component}
    power = PSI.get_system_state_value(state, PSI.ActivePowerVariable(), T)
    return name -> power[name]
end

const _NEMInitialPowerICs = Vector{Union{PSI.InitialCondition{NEMInitialPower, JuMP.VariableRef}, PSI.InitialCondition{NEMInitialPower, Nothing}}}
const _NEMInitialFlowICs = Vector{Union{PSI.InitialCondition{NEMInitialFlow, JuMP.VariableRef}, PSI.InitialCondition{NEMInitialFlow, Nothing}}}

"""
    PSI.update_initial_conditions!(ics::Vector{<:PSI.InitialCondition{NEMInitialPower}}, state, model_resolution)

Sets each unit's starting output to its solved output at the previous interval, read from the simulation's
system state.

# Returns
`nothing`.
"""
function PSI.update_initial_conditions!(ics::_NEMInitialPowerICs, state::PSI.SimulationState, ::Dates.Millisecond)
    isempty(ics) && return
    output = _solved_output(state, PSI.get_component_type(first(ics)))
    for ic in ics
        PSI.set_ic_quantity!(ic, Float64(output(PSI.get_component_name(ic))))
    end
    return
end

"""
    PSI.update_initial_conditions!(ics::Vector{<:PSI.InitialCondition{NEMInitialFlow}}, state, model_resolution)

Sets each MNSP's starting flow to its solved flow at the previous interval, in MW.

# Returns
`nothing`.
"""
function PSI.update_initial_conditions!(ics::_NEMInitialFlowICs, state::PSI.SimulationState, ::Dates.Millisecond)
    isempty(ics) && return
    flow = PSI.get_system_state_value(state, PSI.FlowActivePowerVariable(), PSY.AreaInterchange)
    for ic in ics
        PSI.set_ic_quantity!(ic, Float64(flow[PSI.get_component_name(ic)]) * PSY.get_system_base_power(PSI.get_component(ic)))
    end
    return
end

# --- State-dependent parameters ---------------------------------------------------------------------

"""
    PSI.update_parameter_values!(model::PSI.DecisionModel{NEMClosedLoopDispatchProblem}, key, state)

Updates a time-series parameter of a closed-loop replay: PowerSimulations' own update reads the interval's
series, then each component whose series is state-dependent (see `is_state_dependent_input`) gets the value
`closed_loop_input` computes from its solved output at the previous interval.

# Returns
`nothing`.
"""
function PSI.update_parameter_values!(
        model::PSI.DecisionModel{NEMClosedLoopDispatchProblem}, key::PSI.ParameterKey{P, T}, state::PSI.SimulationState,
    ) where {P <: PSI.TimeSeriesParameter, T <: PSY.Component}
    @invoke PSI.update_parameter_values!(model::PSI.OperationModel, key::PSI.ParameterKey{P, T}, state::PSI.SimulationState)
    container = PSI.get_optimization_container(model)
    param_container = PSI.get_parameter(container, key)
    attributes = PSI.get_attributes(param_container)
    attributes isa PSI.TimeSeriesAttributes || return
    series = PSI.get_time_series_name(attributes)
    AustralianElectricityMarkets.is_state_dependent_input(series) || return
    _update_state_dependent_parameter!(model, param_container, P(), T, series, state)
    return
end

function _update_state_dependent_parameter!(model, param_container, param::P, ::Type{T}, series, state) where {P, T}
    container = PSI.get_optimization_container(model)
    attributes = PSI.get_attributes(param_container)
    array = PSI.get_parameter_array(param_container)
    axes_ = PSI.lookup_additional_axes(array)
    lookup = array.lookup[1]
    t = PSI.get_current_time(model)
    base = PSI.get_base_power(container)
    output = _solved_output(state, T)
    device_model = PSI.get_model(PSI.get_template(model), T)
    written = Dict{String, Tuple{String, Any}}()
    for device in PSI.get_available_components(device_model, PSI.get_system(model))
        name = PSY.get_name(device)
        uuid = get(attributes.component_name_to_ts_uuid, name, nothing)
        isnothing(uuid) && continue
        value = AustralianElectricityMarkets.closed_loop_input(device, series, t, output(name) * base, base)
        isnothing(value) && continue
        if haskey(written, uuid)
            other, previous = written[uuid]
            previous == value || throw(
                ArgumentError(
                    "closed-loop replay: \"$name\" and \"$other\" share the series behind $(series), so their state-dependent values cannot differ.",
                ),
            )
            continue
        end
        written[uuid] = (name, value)
        unwrapped = PSI._unwrap_for_param(param, value, axes_)
        all(isfinite, unwrapped) || throw(ArgumentError("closed-loop replay: the $(series) value of \"$name\" at $t is not finite."))
        PSI._set_param_value_at!(array.data, unwrapped, lookup[uuid], 1)
    end
    _reapply_targets!(param, param_container)
    return
end

_reapply_targets!(::PSI.ConstraintCoefficientParameter, param_container) = PSI._apply_coefficient_targets!(param_container)
_reapply_targets!(::PSI.ConstraintBoundParameter, param_container) = PSI._apply_bound_targets!(param_container)
_reapply_targets!(::PSI.ParameterType, _) = nothing
