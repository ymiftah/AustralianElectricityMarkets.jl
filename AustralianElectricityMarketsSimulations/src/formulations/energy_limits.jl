function PSI.convert_result_to_natural_units(::Type{<:Union{EnergyMaxAvailTimeSeriesParameter, EnergyUIGFTimeSeriesParameter}})
    return true
end

function _energy_limit_parameter(::Type{EnergyMaxAvailConstraint})
    return EnergyMaxAvailTimeSeriesParameter
end

function _energy_limit_parameter(::Type{EnergyUIGFConstraint})
    return EnergyUIGFTimeSeriesParameter
end

function _energy_limit_slack(::Type{EnergyMaxAvailConstraint})
    return EnergyMaxAvailSlack
end

function _energy_limit_slack(::Type{EnergyUIGFConstraint})
    return EnergyUIGFSlack
end

function _energy_limit_cvp(::EnergyMaxAvailSlack)
    return ENERGY_MAX_AVAIL_CVP_FACTOR
end

function _energy_limit_cvp(::EnergyUIGFSlack)
    return ENERGY_UIGF_CVP_FACTOR
end

function _semi_scheduled_devices(devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}}) where {T}
    return T[d for d in devices if is_semi_scheduled(d)]
end

"""
    PSI.add_constraints!(container, constraint_type, variable_type, devices, model, network_model)

Adds an energy availability row for each device and interval, subtracting the corresponding
non-negative surplus from dispatch before applying its live time-series limit.

# Returns
`nothing`.
"""
function PSI.add_constraints!(
        container::PSI.OptimizationContainer, ::Type{C}, ::Type{U},
        devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}},
        ::PSI.DeviceModel{T, D}, ::PSI.NetworkModel{<:PM.AbstractPowerModel},
    ) where {C <: AbstractEnergyLimitConstraint, U <: PSI.VariableType, T <: PSY.StaticInjection, D <: AbstractNEMDispatch}
    isempty(devices) && return
    names = PSY.get_name.(collect(devices))
    steps = PSI.get_time_steps(container)
    limit, covered = _ts_parameter_accessor(container, _energy_limit_parameter(C), T)
    _require_coverage(names, "missing energy-limit series", "Call set_nem_energy_limits! first.", covered)
    power = PSI.get_variable(container, U(), T)
    slack = PSI.get_variable(container, _energy_limit_slack(C)(), T)
    rows = PSI.add_constraints_container!(container, C(), T, names, steps)
    for name in names, t in steps
        rows[name, t] = _energy_limit_row!(container, C, power[name, t], slack[name, t], limit(name, t))
    end
    return
end

"""
    PSI.add_proportional_cost!(container, slack, devices, formulation)

Prices each energy-limit surplus at its AEMO CVP times the interval's Market Price Cap,
converting per-unit dispatch to MW and the interval duration to hours.

# Returns
`nothing`.
"""
function PSI.add_proportional_cost!(
        container::PSI.OptimizationContainer, slack::S,
        devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}}, ::AbstractNEMDispatch,
    ) where {S <: AbstractEnergyLimitSlack, T <: PSY.StaticInjection}
    isempty(devices) && return
    _add_mpc_penalty!(
        container, PSI.get_variable(container, slack, T), [PSY.get_name(d) for d in devices],
        PSI.get_time_steps(container), _energy_limit_cvp(slack),
    )
    return
end

function _energy_limit_parameter(::Type{EnergyMaxAvailOutConstraint})
    return PSI.ActivePowerOutTimeSeriesParameter
end

function _energy_limit_parameter(::Type{EnergyMaxAvailInConstraint})
    return PSI.ActivePowerInTimeSeriesParameter
end

function _energy_limit_slack(::Type{EnergyMaxAvailOutConstraint})
    return EnergyMaxAvailOutSlack
end

function _energy_limit_slack(::Type{EnergyMaxAvailInConstraint})
    return EnergyMaxAvailInSlack
end

function _energy_limit_cvp(::Union{EnergyMaxAvailOutSlack, EnergyMaxAvailInSlack})
    return ENERGY_MAX_AVAIL_CVP_FACTOR
end

function _energy_limit_row!(container, ::Type{<:AbstractEnergyLimitConstraint}, power, slack, limit)
    return JuMP.@constraint(PSI.get_jump_model(container), power - slack <= limit)
end

function _energy_limit_row!(container, ::Type{EnergyMaxAvailInConstraint}, power, slack, limit)
    return JuMP.@constraint(PSI.get_jump_model(container), -power + slack >= -limit)
end
