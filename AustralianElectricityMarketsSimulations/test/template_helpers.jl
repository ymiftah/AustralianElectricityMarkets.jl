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

# Sundance's 100 MW floor exceeds fixture demand under no-commitment dispatch; zero every
# `ThermalStandard` floor before building an `augmented_pscb_system()` template.
function _fix_thermal_floor!(sys)
    for gen in PSY.get_components(PSY.ThermalStandard, sys)
        limits = PSY.get_active_power_limits(gen)
        PSY.set_active_power_limits!(gen, (min = 0.0, max = limits.max))
    end
    return
end
