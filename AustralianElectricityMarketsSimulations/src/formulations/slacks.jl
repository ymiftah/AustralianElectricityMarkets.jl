# Slack variables built per device through `PSI.add_variables!`, under an `AbstractNEMDispatch` model.
const _DEVICE_SLACKS = Union{AbstractEnergyLimitSlack, AbstractEnergyOfferSlack, AbstractFixedLoadSlack}

# Slack variables whose results read back in MW rather than system-base per-unit.
const _NATURAL_UNIT_SLACKS = Union{
    _DEVICE_SLACKS, AbstractMNSPSlack,
    UnitRampUpSlack, UnitRampDownSlack,
    GenericConstraintSlackUp, GenericConstraintSlackDown,
    InterconnectorFlowSurplusSlack, InterconnectorFlowDeficitSlack,
    FCASJointCapacitySlack, FCASJointRampingSlack, FCASMaxAvailSlack, FCASBDURampingSlack,
}


function PSI.get_variable_binary(::_DEVICE_SLACKS, ::Type{<:PSY.StaticInjection}, ::AbstractNEMDispatch)
    return false
end

function PSI.get_variable_lower_bound(::_DEVICE_SLACKS, ::PSY.StaticInjection, ::AbstractNEMDispatch)
    return 0.0
end

function PSI.get_variable_upper_bound(::_DEVICE_SLACKS, ::PSY.StaticInjection, ::AbstractNEMDispatch)
    return nothing
end

function PSI.convert_result_to_natural_units(::Type{<:_NATURAL_UNIT_SLACKS})
    return true
end


"""
    _add_slack_variables!(container, var_type, T, names, time_steps; meta, label = string(nameof(var_type)))

Builds a non-negative variable of `var_type` per `(name, t)`, named `"<label>_{name,t}"`, in a
container keyed by `T` and `meta`. The variables are in system-base per-unit.

# Arguments
- `container`: the `PSI.OptimizationContainer` being built.
- `var_type`: the slack `PSI.VariableType`.
- `T`: the component type the container is keyed by.
- `names`, `time_steps`: the axes of the container.
- `meta`: the container key's meta; empty by default.
- `label`: the prefix of each variable's name.

# Returns
The slack variable container.
"""
function _add_slack_variables!(
        container::PSI.OptimizationContainer, var_type, ::Type{T}, names, time_steps;
        meta = IS.Optimization.CONTAINER_KEY_EMPTY_META, label = string(nameof(var_type)),
    ) where {T}
    jm = PSI.get_jump_model(container)
    slack = PSI.add_variable_container!(container, var_type(), T, names, time_steps; meta = meta)
    for t in time_steps, name in names
        slack[name, t] = JuMP.@variable(jm, base_name = "$(label)_{$name,$t}", lower_bound = 0.0)
    end
    return slack
end


"""
    _add_cvp_slack!(container, var_type, T, names, time_steps, cvp_factor; meta, label, rate = nothing)

Builds the slack variables of [`_add_slack_variables!`](@ref) and prices them in the objective at
`cvp_factor` times the Market Price Cap of the build's initial interval ([`_add_mpc_penalty!`](@ref)), in
`\$/MW` per dispatch interval.

# Arguments
- `container`, `var_type`, `T`, `names`, `time_steps`, `meta`, `label`: as for [`_add_slack_variables!`](@ref).
- `cvp_factor`: the AEMO CVP factor the slack is priced at, times the Market Price Cap.
- `rate`: a Market Price Cap that replaces the dated one, or `nothing`.

# Returns
The slack variable container.
"""
function _add_cvp_slack!(
        container::PSI.OptimizationContainer, var_type, ::Type{T}, names, time_steps, cvp_factor::Real;
        meta = IS.Optimization.CONTAINER_KEY_EMPTY_META, label = string(nameof(var_type)), rate = nothing,
    ) where {T}
    slack = _add_slack_variables!(container, var_type, T, names, time_steps; meta = meta, label = label)
    _add_mpc_penalty!(container, var_type, T, names, cvp_factor; meta = meta, rate = rate)
    return slack
end
