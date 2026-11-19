# Targets per container and parameter key; weak on the container so a finished build's targets go with it.
const _COEFFICIENT_TARGETS = WeakKeyDict{PSI.OptimizationContainer, Dict{PSI.ParameterKey, Vector{_CoefficientTarget}}}()
const _BOUND_TARGETS = WeakKeyDict{PSI.OptimizationContainer, Dict{PSI.ParameterKey, Vector{_BoundTarget}}}()

function _targets_in(store, container::PSI.OptimizationContainer, key::PSI.ParameterKey, ::Type{S}) where {S}
    per_key = get!(() -> Dict{PSI.ParameterKey, Vector{S}}(), store, container)
    return get!(() -> S[], per_key, key)
end
function _targets(::Type{<:NEMConstraintCoefficientParameter}, container, key)
    return _targets_in(_COEFFICIENT_TARGETS, container, key, _CoefficientTarget)
end
function _targets(::Type{<:NEMConstraintBoundParameter}, container, key)
    return _targets_in(_BOUND_TARGETS, container, key, _BoundTarget)
end

function _clear_targets!(container::PSI.OptimizationContainer, key::PSI.ParameterKey{T, U}) where {T <: NEMFloatTimeSeriesParameter, U}
    empty!(_targets(T, container, key))
    return
end

# Storage type of a time-series parameter: JuMP parameter variables for recurrent solves, `Float64` otherwise and for the float parameters.
function _parameter_eltype(container::PSI.OptimizationContainer, ::Type{T}) where {T <: PSI.TimeSeriesParameter}
    float = T <: NEMFloatTimeSeriesParameter || !PSI.built_for_recurrent_solves(container) || PSI.get_rebuild_model(PSI.get_settings(container))
    return float ? Float64 : JuMP.VariableRef
end

# Checks the parameter array of `key` and returns it with the rows of `name` and time step `t`.
function _target_rows(container::PSI.OptimizationContainer, key::PSI.ParameterKey{T, U}, name::String, t::Int) where {T, U}
    PSI.get_rebuild_model(PSI.get_settings(container)) &&
        error("$T does not support models built with rebuild_model = true")
    param_container = PSI.get_parameter(container, key)
    param_array = PSI.get_parameter_array(param_container)
    (param_array isa JuMP.Containers.DenseAxisArray && ndims(param_array) == 2) ||
        error("$T requires a dense (component, time) parameter array")
    1 <= t <= size(param_array, 2) || error("Time step $t is outside the time steps of $T")
    param_row = param_array.lookup[1][PSI._get_ts_uuid(PSI.get_attributes(param_container), name)]
    multiplier_row = PSI.get_multiplier_array(param_container).lookup[1][name]
    return param_container, param_row, multiplier_row
end

"""
    _add_coefficient_target!(container, key, name, t, constraint, variable, scale)

Register the coefficient of `variable` in `constraint` as driven by cell `(name, t)` of the
constraint-coefficient parameter under `key`, and set it to `scale * value * multiplier` from the
current parameter values. Each call adds a target, so repeated calls for one cell duplicate it.

# Arguments
  - `container::PSI.OptimizationContainer`: container holding the parameter.
  - `key::PSI.ParameterKey`: key of a parameter with `T <: NEMConstraintCoefficientParameter`.
  - `name::String`: component name on the parameter's first axis.
  - `t::Int`: time step.
  - `constraint::JuMP.ConstraintRef`: constraint whose coefficient is set.
  - `variable::JuMP.VariableRef`: variable whose coefficient is set.
  - `scale::Float64`: factor applied to the parameter value.

# Returns
`nothing`.
"""
function _add_coefficient_target!(
        container::PSI.OptimizationContainer, key::PSI.ParameterKey{T, U}, name::String, t::Int,
        constraint::JuMP.ConstraintRef, variable::JuMP.VariableRef, scale::Float64,
    ) where {T <: NEMConstraintCoefficientParameter, U}
    param_container, param_row, multiplier_row = _target_rows(container, key, name, t)
    target = _CoefficientTarget(constraint, variable, scale, param_row, multiplier_row, t)
    push!(_targets(T, container, key), target)
    _apply_target!(PSI.get_parameter_array_data(param_container), PSI.get_multiplier_array_data(param_container), target)
    return
end

"""
    _add_bound_target!(container, key, name, t, constraint, active)

Register the interval bounds `active` of `constraint` as driven by cell `(name, t)` of the
constraint-bound parameter under `key`: the row is free where the parameter value times its multiplier
is zero and has bounds `active` elsewhere. Each call adds a target, so repeated calls for one cell duplicate it.

# Arguments
  - `container::PSI.OptimizationContainer`: container holding the parameter.
  - `key::PSI.ParameterKey`: key of a parameter with `T <: NEMConstraintBoundParameter`.
  - `name::String`: component name on the parameter's first axis.
  - `t::Int`: time step.
  - `constraint::JuMP.ConstraintRef`: constraint built as a `MOI.Interval` row.
  - `active::NTuple{2, Float64}`: lower and upper bound of the row when it is active.

# Returns
`nothing`.
"""
function _add_bound_target!(
        container::PSI.OptimizationContainer, key::PSI.ParameterKey{T, U}, name::String, t::Int,
        constraint::JuMP.ConstraintRef, active::NTuple{2, Float64},
    ) where {T <: NEMConstraintBoundParameter, U}
    param_container, param_row, multiplier_row = _target_rows(container, key, name, t)
    target = _BoundTarget(constraint, active[1], active[2], param_row, multiplier_row, t)
    push!(_targets(T, container, key), target)
    _apply_target!(PSI.get_parameter_array_data(param_container), PSI.get_multiplier_array_data(param_container), target)
    return
end

function _apply_target!(param::Matrix{Float64}, mult::Matrix{Float64}, target::_CoefficientTarget)
    JuMP.set_normalized_coefficient(
        target.constraint, target.variable,
        target.scale * param[target.param_row, target.time_step] * mult[target.multiplier_row, target.time_step],
    )
    return
end

function _apply_target!(param::Matrix{Float64}, mult::Matrix{Float64}, target::_BoundTarget)
    value = param[target.param_row, target.time_step] * mult[target.multiplier_row, target.time_step]
    bounds = value == 0.0 ? JuMP.MOI.Interval(-Inf, Inf) : JuMP.MOI.Interval(target.active_lo, target.active_hi)
    JuMP.MOI.set(JuMP.owner_model(target.constraint), JuMP.MOI.ConstraintSet(), target.constraint, bounds)
    return
end

# Applies every target of `key` to the current parameter values; a no-op for parameters without targets.
function _apply_targets!(container::PSI.OptimizationContainer, key::PSI.ParameterKey{T, U}) where {T, U}
    T <: NEMFloatTimeSeriesParameter || return
    param_container = PSI.get_parameter(container, key)
    param = PSI.get_parameter_array_data(param_container)
    mult = PSI.get_multiplier_array_data(param_container)
    for target in _targets(T, container, key)
        _apply_target!(param, mult, target)
    end
    return
end

# Stock value update of a float parameter, then its targets; the service form reads the service named by the key's meta.
function _update_float_parameter!(container::PSI.OptimizationContainer, model::PSI.OperationModel, key::PSI.ParameterKey{T, U}, input) where {T, U}
    param_container = PSI.get_parameter(container, key)
    array = PSI.get_parameter_array(param_container)
    attributes = PSI.get_attributes(param_container)
    if U <: PSY.Service
        service = PSY.get_component(U, PSI.get_system(model), key.meta)
        isnothing(service) && error("Service $(U) named '$(key.meta)' is no longer in the system; cannot update parameter $(key)")
        PSI._update_parameter_values!(array, T(), attributes, service, model, input)
    else
        PSI._update_parameter_values!(array, T(), attributes, U, model, input)
    end
    _apply_targets!(container, key)
    return
end

function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer, model::PSI.OperationModel,
        key::PSI.ParameterKey{T, U}, input::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: NEMFloatTimeSeriesParameter, U <: PSY.Component}
    _update_float_parameter!(container, model, key, input)
    return
end

function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer, model::PSI.OperationModel,
        key::PSI.ParameterKey{T, U}, input::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: NEMFloatTimeSeriesParameter, U <: PSY.Service}
    _update_float_parameter!(container, model, key, input)
    return
end
