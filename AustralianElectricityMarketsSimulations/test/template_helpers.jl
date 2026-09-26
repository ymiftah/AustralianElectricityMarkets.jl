# Private test-only `PSI.ProblemTemplate` builders for the PSCB fixture, not part of the
# package's public API.

import PowerSimulations as PSI
import PowerSystems as PSY
import HydroPowerSimulations

"Per-area balances via `AreaBalancePowerModel`. Mirrors `docs/literate/interchanges.jl`."
function _area_balance_template()
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
