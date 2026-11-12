function PSI.convert_result_to_natural_units(::Type{<:Union{EnergyMaxAvailTimeSeriesParameter, EnergyUIGFTimeSeriesParameter}})
    return true
end

_energy_limit_parameter(::EnergyLimitMaxAvailVariant) = EnergyMaxAvailTimeSeriesParameter
_energy_limit_parameter(::EnergyLimitUIGFVariant) = EnergyUIGFTimeSeriesParameter
_energy_limit_parameter(::EnergyLimitMaxAvailOutVariant) = PSI.ActivePowerOutTimeSeriesParameter
_energy_limit_parameter(::EnergyLimitMaxAvailInVariant) = PSI.ActivePowerInTimeSeriesParameter

# The key meta of each energy limit row in its `NEMUnitConstraint` container.
_energy_limit_row_meta(::EnergyLimitMaxAvailVariant) = "max_avail"
_energy_limit_row_meta(::EnergyLimitUIGFVariant) = "uigf"
_energy_limit_row_meta(::EnergyLimitMaxAvailOutVariant) = "max_avail_out"
_energy_limit_row_meta(::EnergyLimitMaxAvailInVariant) = "max_avail_in"

function _energy_limit_cvp(::EnergyLimitMaxAvailVariant)
    return ENERGY_MAX_AVAIL_CVP_FACTOR
end

function _energy_limit_cvp(::EnergyLimitUIGFVariant)
    return ENERGY_UIGF_CVP_FACTOR
end

function _energy_limit_cvp(::Union{EnergyLimitMaxAvailOutVariant, EnergyLimitMaxAvailInVariant})
    return ENERGY_MAX_AVAIL_CVP_FACTOR
end

function _semi_scheduled_devices(devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}}) where {T}
    return T[d for d in devices if is_semi_scheduled(d)]
end

"""
    _add_energy_limit_rows!(container, variant, U, devices, model, network_model)

Adds the energy limit rows of `variant` for each device and interval, a [`NEMUnitConstraint`](@ref)
row under the variant's meta. Each subtracts the variant's non-negative surplus from the `U` variable before
applying its live time-series limit.

# Arguments
- `container`: the `PSI.OptimizationContainer` being built.
- `variant`: the energy limit variant, which picks the limit parameter, the slack and the meta.
- `U`: the `PSI.VariableType` of the dispatch the row bounds.
- `devices`: the devices of `model`.
- `model`: the `PSI.DeviceModel` with an [`AbstractNEMDispatch`](@ref) formulation.
- `network_model`: the `PSI.NetworkModel` of the build.

# Returns
`nothing`.
"""
function _add_energy_limit_rows!(
        container::PSI.OptimizationContainer, variant::_EnergyLimitVariant, ::Type{U},
        devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}},
        ::PSI.DeviceModel{T, D}, ::PSI.NetworkModel{<:PM.AbstractPowerModel},
    ) where {U <: PSI.VariableType, T <: PSY.StaticInjection, D <: AbstractNEMDispatch}
    isempty(devices) && return
    names = PSY.get_name.(collect(devices))
    steps = PSI.get_time_steps(container)
    limit, covered = _ts_parameter_accessor(container, _energy_limit_parameter(variant), T)
    _require_coverage(names, "missing energy-limit series", "Call set_unit_conditions! first.", covered)
    power = PSI.get_variable(container, U(), T)
    slack = PSI.get_variable(container, NEMUnitSlack(), T, _nem_unit_slack_meta(variant))
    rows = PSI.add_constraints_container!(
        container, NEMUnitConstraint(), T, names, steps; meta = _energy_limit_row_meta(variant),
    )
    for name in names, t in steps
        rows[name, t] = _energy_limit_row!(container, variant, power[name, t], slack[name, t], limit(name, t))
    end
    return
end

function _energy_limit_row!(container, ::_EnergyLimitVariant, power, slack, limit)
    return JuMP.@constraint(PSI.get_jump_model(container), power - slack <= limit)
end

function _energy_limit_row!(container, ::EnergyLimitMaxAvailInVariant, power, slack, limit)
    return JuMP.@constraint(PSI.get_jump_model(container), -power + slack >= -limit)
end
