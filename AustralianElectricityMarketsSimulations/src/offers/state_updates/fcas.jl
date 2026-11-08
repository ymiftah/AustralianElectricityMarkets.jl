# Per-step updates of the FCAS effective offers and regulation ramping limits.

# The bid type and offer side a parameter's meta names, `"<BIDTYPE>"` or `"<BIDTYPE>_decremental"`.
function _fcas_meta_offer(meta::AbstractString)
    suffix = "_decremental"
    decremental = endswith(meta, suffix)
    name = decremental ? meta[1:(end - length(suffix))] : meta
    return BidType(name), decremental
end


"""
    _update_fcas_parameters!(field_slice, kind, container, model, key) -> nothing

Writes the FCAS effective offer or regulation ramping limit of every device the parameter was built
for at every step of `model`'s horizon, recomputed through [`_fcas_effective_values`](@ref) from the
unit's [`NEMUnitState`](@ref) at the step, read through the configured [`StateSource`](@ref), and its
[`_FCASWindow`](@ref). The values are per-unit of the system base, as the series were attached.
`field_slice` selects the parameter's own entries of one offer or ramping-limit element.

# Arguments
- `field_slice`: `element -> value`, the parameter's entries of one element.
- `kind`: `:offer` for an effective offer parameter, `:ramping` for a ramping limit parameter.
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter; its meta names the market and side.

# Returns
`nothing`.
"""
function _update_fcas_parameters!(
        field_slice::Function, kind::Symbol, container::PSI.OptimizationContainer,
        model::PSI.OperationModel, key::PSI.ParameterKey{P, T},
    ) where {P, T}
    parameter_array = PSI.get_parameter_array(container, key)
    parent_param = PSI.get_parameter_array_data(PSI.get_parameter(container, key))
    attributes = PSI.get_parameter_attributes(container, key)
    steps = PSI.get_time_steps(container)
    system = PSI.get_system(model)
    bid_type, decremental = _fcas_meta_offer(key.meta)
    PSY.with_units_base(system, "SYSTEM_BASE") do
        base = PSY.get_base_power(system)
        inactive = FCAS_INACTIVE_LIMIT_MW / base
        window = _FCASWindow(PSI.get_current_timestamp(model), length(steps), PSI.get_resolution(model))
        for (name, uuid) in attributes.component_name_to_ts_uuid
            device = PSY.get_component(T, system, name)
            # The effective offers and ramping limits read the starting output, in system-base
            # per unit, so they are rebuilt from the step's state here.
            state = t -> begin
                unit = unit_state(_state_source(), device, _step_stamp(model, t))
                return NEMUnitState(unit.initial_mw / base, unit.dispatch_mode)
            end
            offers, ramping = _fcas_effective_values(
                window, device, bid_type, fcas_bid_direction(device, bid_type), inactive; state,
            )
            values = kind === :ramping ? ramping : offers[decremental]
            i = parameter_array.lookup[1][uuid]
            for t in steps
                PSI._set_param_value_at!(parent_param, field_slice(values[t]), i, t)
            end
        end
    end
    return
end


# The slope parameters set a constraint coefficient through the stock `add_coefficient_target!`
# registration, so a new value only reaches its row once the registered coefficients are rewritten.
function _apply_fcas_slope_coefficients!(container::PSI.OptimizationContainer, key::PSI.ParameterKey)
    PSI._apply_coefficient_targets!(PSI.get_parameter(container, key))
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`FCASOfferLimitParameter`](@ref) from each device's effective FCAS offer and
[`NEMUnitState`](@ref) at the step: `MaxAvail`, `EnablementMin` and `EnablementMax`, per-unit of the
system base.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{FCASOfferLimitParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_fcas_parameters!(v -> [v[1], v[2], v[3]], :offer, container, model, key)
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`FCASBandWidthParameter`](@ref) from each device's effective FCAS offer and
[`NEMUnitState`](@ref) at the step: the ten band widths, per-unit of the system base.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{FCASBandWidthParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_fcas_parameters!(v -> collect(v[6:15]), :offer, container, model, key)
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`FCASUpperSlopeParameter`](@ref) from each device's effective FCAS offer and
[`NEMUnitState`](@ref) at the step: the upper slope coefficient.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{FCASUpperSlopeParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_fcas_parameters!(v -> v[4], :offer, container, model, key)
    _apply_fcas_slope_coefficients!(container, key)
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`FCASLowerSlopeParameter`](@ref) from each device's effective FCAS offer and
[`NEMUnitState`](@ref) at the step: the lower slope coefficient.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{FCASLowerSlopeParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_fcas_parameters!(v -> v[5], :offer, container, model, key)
    _apply_fcas_slope_coefficients!(container, key)
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`FCASRampingLimitParameter`](@ref) from each device's AGC ramping capability and
[`NEMUnitState`](@ref) at the step, through [`fcas_ramping_active`](@ref) and
[`fcas_ramping_limit`](@ref): the joint ramping limit and the battery's BDU ramping limit, per-unit
of the system base.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{FCASRampingLimitParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_fcas_parameters!(v -> [v[1], v[2]], :ramping, container, model, key)
    return
end
