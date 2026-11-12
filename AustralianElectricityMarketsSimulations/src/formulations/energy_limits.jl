function PSI.convert_result_to_natural_units(::Type{<:Union{EnergyMaxAvailTimeSeriesParameter, EnergyUIGFTimeSeriesParameter}})
    return true
end

function _energy_limit_parameter(::Type{EnergyMaxAvailConstraint})
    return EnergyMaxAvailTimeSeriesParameter
end

function _energy_limit_parameter(::Type{EnergyUIGFConstraint})
    return EnergyUIGFTimeSeriesParameter
end

function _energy_limit_constraint_variant(::Type{EnergyMaxAvailConstraint})
    return EnergyLimitMaxAvailVariant()
end

function _energy_limit_constraint_variant(::Type{EnergyUIGFConstraint})
    return EnergyLimitUIGFVariant()
end

function _energy_limit_cvp(::EnergyLimitMaxAvailVariant)
    return ENERGY_MAX_AVAIL_CVP_FACTOR
end

function _energy_limit_cvp(::EnergyLimitUIGFVariant)
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
    _require_coverage(names, "missing energy-limit series", "Call set_unit_conditions! first.", covered)
    power = PSI.get_variable(container, U(), T)
    slack = PSI.get_variable(container, NEMUnitSlack(), T, _nem_unit_slack_meta(_energy_limit_constraint_variant(C)))
    rows = PSI.add_constraints_container!(container, C(), T, names, steps)
    for name in names, t in steps
        rows[name, t] = _energy_limit_row!(container, C, power[name, t], slack[name, t], limit(name, t))
    end
    return
end

function _energy_limit_parameter(::Type{EnergyMaxAvailOutConstraint})
    return PSI.ActivePowerOutTimeSeriesParameter
end

function _energy_limit_parameter(::Type{EnergyMaxAvailInConstraint})
    return PSI.ActivePowerInTimeSeriesParameter
end

function _energy_limit_constraint_variant(::Type{EnergyMaxAvailOutConstraint})
    return EnergyLimitMaxAvailOutVariant()
end

function _energy_limit_constraint_variant(::Type{EnergyMaxAvailInConstraint})
    return EnergyLimitMaxAvailInVariant()
end

function _energy_limit_cvp(::Union{EnergyLimitMaxAvailOutVariant, EnergyLimitMaxAvailInVariant})
    return ENERGY_MAX_AVAIL_CVP_FACTOR
end

function _energy_limit_row!(container, ::Type{<:AbstractEnergyLimitConstraint}, power, slack, limit)
    return JuMP.@constraint(PSI.get_jump_model(container), power - slack <= limit)
end

function _energy_limit_row!(container, ::Type{EnergyMaxAvailInConstraint}, power, slack, limit)
    return JuMP.@constraint(PSI.get_jump_model(container), -power + slack >= -limit)
end
