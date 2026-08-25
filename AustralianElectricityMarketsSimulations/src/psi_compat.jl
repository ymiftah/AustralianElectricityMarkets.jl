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
