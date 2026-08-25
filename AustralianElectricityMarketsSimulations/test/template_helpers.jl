# Private test-only equivalent of the removed FidelityTier machinery (T0CopperPlate/
# T1Interconnected/build_template) — a development/verification artefact, not part of the
# package's public API. Kept as plain functions, not a type hierarchy: nothing here needs to
# dispatch generically over "any tier".

import PowerSimulations as PSI
import PowerSystems as PSY
import HydroPowerSimulations

"Copper-plate, energy-only `PSI.ProblemTemplate`. Mirrors `docs/literate/economic_dispatch.jl`."
function _t0_template()
    template = PSI.ProblemTemplate()
    PSI.set_device_model!(template, PSY.Line, PSI.StaticBranch)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_device_model!(template, PSY.RenewableDispatch, PSI.RenewableFullDispatch)
    PSI.set_device_model!(template, PSY.ThermalStandard, PSI.ThermalBasicDispatch)
    PSI.set_device_model!(template, PSY.HydroDispatch, HydroPowerSimulations.HydroDispatchRunOfRiver)
    PSI.set_network_model!(
        template,
        PSI.NetworkModel(PSI.CopperPlatePowerModel; duals = [PSI.CopperPlateBalanceConstraint]),
    )
    return template
end

"Per-area balances via `AreaBalancePowerModel`. Mirrors `docs/literate/interchanges.jl`."
function _t1_template()
    template = PSI.ProblemTemplate()
    PSI.set_device_model!(template, PSY.Line, PSI.StaticBranch)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_device_model!(template, PSY.RenewableDispatch, PSI.RenewableFullDispatch)
    PSI.set_device_model!(template, PSY.ThermalStandard, PSI.ThermalBasicUnitCommitment)
    PSI.set_device_model!(template, PSY.HydroDispatch, HydroPowerSimulations.HydroDispatchRunOfRiver)
    PSI.set_network_model!(
        template,
        PSI.NetworkModel(
            PSI.AreaBalancePowerModel; use_slacks = true, duals = [PSI.CopperPlateBalanceConstraint],
        ),
    )
    PSI.set_device_model!(template, PSY.AreaInterchange, PSI.StaticBranch)
    return template
end
