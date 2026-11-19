# Slack variables whose results read back in MW rather than system-base per-unit.
const _NATURAL_UNIT_SLACKS = Union{
    NEMUnitSlack, MNSPSlack,
    GenericConstraintSlackUp, GenericConstraintSlackDown,
    InterconnectorFlowSlack,
    FCASSlack,
    AreaBalanceSlack,
}


function PSI.convert_result_to_natural_units(::Type{<:_NATURAL_UNIT_SLACKS})
    return true
end


# The AEMO CVP factor each unit slack variant is priced at.
_nem_unit_slack_cvp(::_EnergyOfferVariant) = ENERGY_OFFER_CVP_FACTOR
_nem_unit_slack_cvp(variant::_EnergyLimitVariant) = _energy_limit_cvp(variant)
_nem_unit_slack_cvp(::_FixedLoadVariant) = FIXED_LOADING_CVP_FACTOR
_nem_unit_slack_cvp(::_UnitRampVariant) = UNIT_RAMP_CVP_FACTOR
_nem_unit_slack_cvp(::_FastStartVariant) = FAST_START_CVP_FACTOR


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


"""
    _add_area_balance_slacks!(container, sys, network_model)

Adds the [`AreaBalanceSlack`](@ref) deficit and surplus to each area's `ActivePowerBalance`, priced at
[`AREA_BALANCE_CVP_FACTOR`](@ref) times the Market Price Cap. Called from the argument stage of every AEMSim
formulation that writes to the area balance, so it runs before the balance row is built. For an
`AreaBalancePowerModel` and unless the `"area_balance_slacks"` setting is `false`, it turns PSI's own balance
slacks off on the build's network model and adds the slacks once per container. A template with no such
formulation never calls it and keeps the caller's `use_slacks`.

# Arguments
- `container`: the `PSI.OptimizationContainer` being built.
- `sys`: the system the build runs on.
- `network_model`: the network model of the build; mutated to turn off its own balance slacks.

# Returns
`nothing`.
"""
function _add_area_balance_slacks!(container::PSI.OptimizationContainer, sys::PSY.System, network_model::PSI.NetworkModel)
    network_model isa PSI.NetworkModel{PSI.AreaBalancePowerModel} || return
    get(PSI.get_ext(PSI.get_settings(container)), "area_balance_slacks", true) || return
    PSI.has_container_key(container, AreaBalanceSlack, PSY.Area, AREA_BALANCE_DEFICIT) && return
    network_model.use_slacks = false
    areas = PSY.get_name.(PSI.get_available_components(network_model, PSY.Area, sys))
    time_steps = PSI.get_time_steps(container)
    expression = PSI.get_expression(container, PSI.ActivePowerBalance(), PSY.Area)
    for (meta, sign) in ((AREA_BALANCE_DEFICIT, 1.0), (AREA_BALANCE_SURPLUS, -1.0))
        slack = _add_cvp_slack!(
            container, AreaBalanceSlack, PSY.Area, areas, time_steps, AREA_BALANCE_CVP_FACTOR;
            meta = meta, label = "AreaBalance_$meta",
        )
        for t in time_steps, area in areas
            JuMP.add_to_expression!(expression[area, t], sign, slack[area, t])
        end
    end
    return
end


"""
    _add_unit_slack_variables!(container, variant, T, names, time_steps)

Builds the [`NEMUnitSlack`](@ref) variables of `variant` for `names` of `T`, keyed by the variant's meta.

# Returns
The slack variable container.
"""
function _add_unit_slack_variables!(
        container::PSI.OptimizationContainer, variant, ::Type{T}, names, time_steps,
    ) where {T}
    return _add_slack_variables!(
        container, NEMUnitSlack, T, names, time_steps;
        meta = _nem_unit_slack_meta(variant), label = _nem_unit_slack_label(variant),
    )
end


"""
    _add_unit_slack_penalty!(container, variant, T, names)

Prices the [`NEMUnitSlack`](@ref) variables of `variant` for `names` of `T` at the variant's CVP factor
times the Market Price Cap ([`_add_mpc_penalty!`](@ref)).

# Returns
`nothing`.
"""
function _add_unit_slack_penalty!(container::PSI.OptimizationContainer, variant, ::Type{T}, names) where {T}
    _add_mpc_penalty!(
        container, NEMUnitSlack, T, names, _nem_unit_slack_cvp(variant); meta = _nem_unit_slack_meta(variant),
    )
    return
end


"""
    _add_device_unit_slacks!(container, variant, devices)

Builds the [`NEMUnitSlack`](@ref) variables of `variant` for `devices`, or nothing when `devices` is empty.

# Returns
`nothing`.
"""
function _add_device_unit_slacks!(
        container::PSI.OptimizationContainer, variant,
        devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}},
    ) where {T <: PSY.StaticInjection}
    isempty(devices) && return
    _add_unit_slack_variables!(container, variant, T, PSY.get_name.(devices), PSI.get_time_steps(container))
    return
end


"""
    _add_device_unit_slack_costs!(container, variant, devices)

Prices the [`NEMUnitSlack`](@ref) variables of `variant` for `devices`, or nothing when `devices` is empty.

# Returns
`nothing`.
"""
function _add_device_unit_slack_costs!(
        container::PSI.OptimizationContainer, variant,
        devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}},
    ) where {T <: PSY.StaticInjection}
    isempty(devices) && return
    _add_unit_slack_penalty!(container, variant, T, PSY.get_name.(devices))
    return
end
