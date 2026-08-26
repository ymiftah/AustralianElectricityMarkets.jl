# Type piracy quarantined here on purpose: this is the *only* place in this package that
# extends a `PowerSimulations.jl` method with no NEM/AEM type in the signature. Check this
# file first on every PSI upgrade - once upstream registers a `PSY.Area`-keyed dual for
# `AreaBalancePowerModel`, this method must be deleted.

"""
    PSI.add_constraint_dual!(container, sys, model::PSI.NetworkModel{PSI.AreaBalancePowerModel})

Works around a gap in `PowerSimulations.jl`: dual registration for `NetworkModel` falls back to
a generic method that keys duals by `PSY.ACBus`, correct for nodal (PTDF/DC) network models —
but `AreaBalancePowerModel`'s own `CopperPlateBalanceConstraint` is `PSY.Area`-keyed
(`network_models/area_balance_model.jl`), so that fallback registers a dual container PSI can
never fill. Whenever `ThermalBasicUnitCommitment` makes the problem a MILP,
`calculate_dual_variables!` then crashes recomputing duals ("constraint
CopperPlateBalanceConstraint__ACBus is not stored"); `CopperPlatePowerModel` (T0) is unaffected
because it already has its own `System`-keyed overload. This adds the missing `Area`-keyed one,
mirroring that existing pattern exactly (same `add_constraints!` call site,
`network_models/area_balance_model.jl:1-21`) rather than computing anything by hand — no shadow
JuMP model, just the correct dual container shape.

Confirmed still present (byte-identical `add_constraint_dual.jl`/`area_balance_model.jl`) across
`PowerSimulations.jl` 0.34.2, 0.38.2, and 0.38.3 — the version actually installed. Delete this
method once a PSI release adds its own `PSY.Area`-keyed `add_constraint_dual!` for
`AreaBalancePowerModel`.
"""
function PSI.add_constraint_dual!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        model::PSI.NetworkModel{PSI.AreaBalancePowerModel},
    )
    if !isempty(PSI.get_duals(model))
        expressions = PSI.get_expression(container, PSI.ActivePowerBalance(), PSY.Area)
        area_names, time_steps = axes(expressions)
        for constraint_type in PSI.get_duals(model)
            PSI.add_dual_container!(container, constraint_type, PSY.Area, area_names, time_steps)
        end
    end
    return
end

const _NoServiceDeviceModel = Union{
    PSI.ServiceModel{GenericConstraint, TermConstraint},
    PSI.ServiceModel{NEMFCASService, NEMFCASMarket},
}

"""
    PSI._modify_device_model!(devices_template, ::_NoServiceDeviceModel, contributing_devices)

No-op override of a PSI *private* function (`operation/problem_template.jl`, unexported,
underscore-prefixed). `_add_services_to_device_model!` calls it unconditionally for every
`ServiceModel` with a non-empty contributing-devices list — there is no fallback method, so a
`Service` formulation without one raises a `MethodError` at template-finalization time, before
`construct_service!` is ever reached. The generic `PSY.Reserve` method pushes `service_model`
onto each contributing device's own `DeviceModel.services` list; neither `TermConstraint` (LHS
assembled directly from the service's own stored terms, `services/nem_constraints.jl`) nor
`NEMFCASMarket` (headroom coupling assembled directly in `construct_service!`,
`services/fcas_market.jl`) needs that, mirroring `TransmissionInterface`'s own no-op override of
this same hook (`services_models/transmission_interface.jl`) for the same reason.

Confirmed present at this location, unexported, underscore-prefixed, with zero external
precedent, across `PowerSimulations.jl` 0.34.2, 0.38.2, and 0.38.3 (`fSDT9` — the version this
package's Manifest installs). Not type piracy under Aqua.jl's definition — every type in
`_NoServiceDeviceModel` is this package's own — but IS fragile coupling to an unexported,
undocumented implementation detail: a future PSI patch could rename or restructure
`_modify_device_model!` with no deprecation. Delete or update this method if that happens.
"""
function PSI._modify_device_model!(
        ::Dict{Symbol, PSI.DeviceModel},
        ::_NoServiceDeviceModel,
        ::Vector,
    )
    return nothing
end
