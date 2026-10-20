function PSI.get_variable_binary(::AbstractEnergyLimitSlack, ::Type{<:PSY.StaticInjection}, ::AbstractNEMDispatch)
    return false
end

function PSI.get_variable_lower_bound(::AbstractEnergyLimitSlack, ::PSY.StaticInjection, ::AbstractNEMDispatch)
    return 0.0
end

function PSI.get_variable_upper_bound(::AbstractEnergyLimitSlack, ::PSY.StaticInjection, ::AbstractNEMDispatch)
    return nothing
end

function PSI.convert_result_to_natural_units(::Type{<:AbstractEnergyLimitSlack})
    return true
end

function PSI.convert_result_to_natural_units(::Type{EnergyMaxAvailTimeSeriesParameter})
    return true
end

function PSI.convert_result_to_natural_units(::Type{EnergyUIGFTimeSeriesParameter})
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
    return T[d for d in devices if PSY.get_ext(d)["nem_semi_scheduled"]]
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
    variables = PSI.get_variable(container, slack, T)
    resolution = PSI.get_resolution(container)
    for t in PSI.get_time_steps(container)
        time = PSI.get_initial_time(container) + (t - 1) * resolution
        cost = PSI.get_base_power(container) * interval_cost_coefficient(
            _energy_limit_cvp(slack) * _container_market_price_cap(container, time), resolution,
        )
        for d in devices
            PSI.add_to_objective_invariant_expression!(container, variables[PSY.get_name(d), t] * cost)
        end
    end
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
