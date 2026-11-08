# Per-step updates of the parameters that read a unit's state: the ramp base from the observed
# initial MW, and the fixed-loading target and invoked flag from the bid and the fast-start mode.
# PowerSimulations calls these after it clears the objective's variant terms, so any objective term
# a method adds is counted once.

"""
    _step_stamp(model, t) -> DateTime

The first timestamp of step `t` of `model`'s current horizon, which is the horizon's first step.

# Arguments
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `t`: the step index.

# Returns
A `DateTime`.
"""
function _step_stamp(model::PSI.OperationModel, t::Integer)
    return PSI.get_current_timestamp(model) + (t - 1) * PSI.get_resolution(model)
end


"""
    _update_state_parameters!(value_at, container, model, key) -> nothing

Writes `value_at(device, stamp)` into every row of the time-series parameter `key` at every step of
`model`'s horizon, in the units its multiplier scales. Only the devices the parameter was built for
are written.

# Arguments
- `value_at`: `(device, stamp) -> Float64`, the value before the multiplier.
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter to update.

# Returns
`nothing`.
"""
function _update_state_parameters!(value_at, container::PSI.OptimizationContainer, model::PSI.OperationModel, key::PSI.ParameterKey{P, T}) where {P, T}
    parameter_array = PSI.get_parameter_array(container, key)
    parent_param = PSI.get_parameter_array_data(PSI.get_parameter(container, key))
    attributes = PSI.get_parameter_attributes(container, key)
    steps = PSI.get_time_steps(container)
    system = PSI.get_system(model)
    for (name, uuid) in attributes.component_name_to_ts_uuid
        device = PSY.get_component(T, system, name)
        i = parameter_array.lookup[1][uuid]
        for t in steps
            PSI._set_param_value_at!(parent_param, Float64(value_at(device, _step_stamp(model, t))), i, t)
        end
    end
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`InitialPowerTimeSeriesParameter`](@ref) from each device's [`NEMUnitState`](@ref) at the
step, read through [`ObservedState`](@ref). The value is the unit's starting MW, which the parameter's
multiplier converts to system-base per-unit.

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
        key::PSI.ParameterKey{InitialPowerTimeSeriesParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_state_parameters!(container, model, key) do device, stamp
        return unit_state(ObservedState(), device, stamp).initial_mw
    end
    return
end


# The raw `FIXEDLOAD` of `device`'s `side` energy bid at `stamp`, MW; `NaN` when the bid has none.
function _fixed_load_mw(device, side::OfferSide, stamp::DateTime)
    cost = _nem_offer_cost(device)
    bid = isnothing(cost) ? nothing : _energy_bid(cost, side)
    isnothing(bid) && return NaN
    value = _state_value(device, bid, :fixed_load, stamp)
    return isnothing(value) ? NaN : Float64(value)
end


# The fixed-loading target on the net-injection axis at `stamp`, MW, and whether either side applies.
function _fixed_load_step(device, stamp::DateTime)
    state = unit_state(ObservedState(), device, stamp)
    gen = _fixed_load_mw(device, OfferSide.GEN, stamp)
    load = _fixed_load_mw(device, OfferSide.LOAD, stamp)
    target = if device isa PSY.Storage
        effective_fixed_load(gen, state) - effective_fixed_load(load, state)
    else
        effective_fixed_load(gen, state) + effective_fixed_load(load, state)
    end
    return (; target, invoked = fixed_load_invoked(gen, state) || fixed_load_invoked(load, state))
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`FixedLoadTimeSeriesParameter`](@ref) from each device's energy bids and
[`NEMUnitState`](@ref) at the step, read through [`ObservedState`](@ref): the net injection at the
device's [`effective_fixed_load`](@ref), in system-base per-unit. A storage device's load side is
subtracted from its generation side; the loading is zero wherever it is not invoked.

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
        key::PSI.ParameterKey{FixedLoadTimeSeriesParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    base_power = PSI.get_base_power(container)
    _update_state_parameters!(container, model, key) do device, stamp
        return _fixed_load_step(device, stamp).target / base_power
    end
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`FixedLoadInvokedTimeSeriesParameter`](@ref) from each device's energy bids and
[`NEMUnitState`](@ref) at the step, read through [`ObservedState`](@ref): `1` where either side's
loading applies and `0` otherwise.

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
        key::PSI.ParameterKey{FixedLoadInvokedTimeSeriesParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_state_parameters!(container, model, key) do device, stamp
        return _fixed_load_step(device, stamp).invoked ? 1.0 : 0.0
    end
    return
end
