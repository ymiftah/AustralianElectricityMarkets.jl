# Extensions of `PowerSimulations.jl` methods, quarantined here on purpose: this is the only
# place in this package that extends a PSI method with no NEM/AEM type in its signature. Check
# this file first on every PSI upgrade.

"""
    _psi_registers_area_balance_dual() -> Bool

Whether the installed `PowerSimulations.jl` has an `AreaBalancePowerModel`-specific
`PSI.add_constraint_dual!`. PSI's generic `NetworkModel` method matches that signature too, so
the test is whether the method `which` selects is the specific one rather than the fallback.
`unwrap_unionall` because a fallback's signature is a `UnionAll` over its network type
parameter, and only a plain `DataType` exposes `parameters`.
"""
function _psi_registers_area_balance_dual()
    network_model = PSI.NetworkModel{PSI.AreaBalancePowerModel}
    method = which(
        PSI.add_constraint_dual!,
        Tuple{PSI.OptimizationContainer, PSY.System, network_model},
    )
    return Base.unwrap_unionall(method.sig).parameters[4] === network_model
end

# Registers the `PSY.Area`-keyed duals that `AreaBalancePowerModel`'s own
# `CopperPlateBalanceConstraint` is stored under. PSI's generic `NetworkModel` method keys them
# by `PSY.ACBus` instead, so `calculate_dual_variables!` looks up a constraint that was never
# stored ("constraint CopperPlateBalanceConstraint__ACBus is not stored").
#
# Defined only when the installed PSI has no `AreaBalancePowerModel` method of its own:
# defining it unconditionally overwrites PSI's, which is a precompilation error.
if !_psi_registers_area_balance_dual()
    function PSI.add_constraint_dual!(
            container::PSI.OptimizationContainer,
            sys::PSY.System,
            model::PSI.NetworkModel{PSI.AreaBalancePowerModel},
        )
        if !isempty(PSI.get_duals(model))
            expressions = PSI.get_expression(container, PSI.ActivePowerBalance(), PSY.Area)
            area_names, time_steps = axes(expressions)
            for constraint_type in PSI.get_duals(model)
                PSI.add_dual_container!(
                    container, constraint_type, PSY.Area, area_names, time_steps,
                )
            end
        end
        return
    end
end

const _NoServiceDeviceModel = Union{
    PSI.ServiceModel{GenericConstraint, TermConstraint},
    PSI.ServiceModel{NEMFCASService, NEMFCASMarket},
}

"""
    PSI._modify_device_model!(devices_template, ::_NoServiceDeviceModel, contributing_devices)

No-op override of a PSI private function (`operation/problem_template.jl`).
`_add_services_to_device_model!` calls it unconditionally for every `ServiceModel` with a
non-empty contributing-devices list and there is no fallback method, so a `Service` formulation
without one raises a `MethodError` at template-finalization time. The generic `PSY.Reserve`
method pushes `service_model` onto each contributing device's own `DeviceModel.services` list;
neither `TermConstraint` nor `NEMFCASMarket` needs that — both assemble their own constraints
directly in `construct_service!`. Mirrors `TransmissionInterface`'s no-op override of the same
hook (`services_models/transmission_interface.jl`).
"""
function PSI._modify_device_model!(
        ::Dict{Symbol, PSI.DeviceModel},
        ::_NoServiceDeviceModel,
        ::Vector,
    )
    return nothing
end

"""
    PSI.get_initial_conditions_service_model(model, service_model::PSI.ServiceModel{GenericConstraint, TermConstraint})

No-op override (`initial_conditions/initialization.jl`). `get_initial_conditions_template`
calls this for every registered `ServiceModel` when building the sub-model PSI derives
ramp/commitment initial conditions from, and there is no fallback method, so a service
formulation without one raises a `MethodError` there. `TermConstraint` carries no
ramp/commitment state of its own to initialize. Mirrors `TransmissionInterface`'s override of
the same hook.

Only reachable once a template's *device* formulation needs initial conditions:
`ThermalStandardDispatch`'s ramp constraints do, `ThermalBasicUnitCommitment` never enters this
path at all.
"""
function PSI.get_initial_conditions_service_model(
        ::PSI.OperationModel,
        ::PSI.ServiceModel{GenericConstraint, TermConstraint},
    )
    return PSI.ServiceModel(GenericConstraint, TermConstraint)
end
