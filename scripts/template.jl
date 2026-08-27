# Replication/validation tooling, not package code - lives here rather than in `src/`, same
# reasoning that moved the earlier `FidelityTier` harness out: this exists to confirm the
# machinery already shipped in `AustralianElectricityMarketsSimulations` (`TermConstraint`,
# `NEMFCASMarket`) reproduces real NEMDE dispatch, not to extend the package's own API.

using AustralianElectricityMarkets
using AustralianElectricityMarketsSimulations
import PowerSimulations as PSI
import PowerSystems as PSY
import HydroPowerSimulations
import StorageSystemsSimulations

"""
    dispatch_replication_template() -> PSI.ProblemTemplate

The `PSI.ProblemTemplate` the replication pipeline solves against: per-area balances via
`AreaBalancePowerModel` (mirrors `docs/literate/interchanges.jl`), storage via
`StorageDispatchWithReserves` (mirrors `docs/literate/clearing-with-batteries.jl`), with
`TermConstraint`/`NEMFCASMarket` registered so NEM generic constraints and FCAS trapezium/joint-
capacity coupling are enforced exactly as validated in
`AustralianElectricityMarketsSimulations/test/{nem_constraints,fcas_market}.jl`.
"""
function dispatch_replication_template()
    template = PSI.ProblemTemplate()
    PSI.set_device_model!(template, PSY.Line, PSI.StaticBranch)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_device_model!(template, PSY.RenewableDispatch, PSI.RenewableFullDispatch)
    PSI.set_device_model!(template, PSY.ThermalStandard, PSI.ThermalBasicUnitCommitment)
    PSI.set_device_model!(template, PSY.HydroDispatch, HydroPowerSimulations.HydroDispatchRunOfRiver)
    PSI.set_device_model!(
        template,
        PSI.DeviceModel(
            PSY.EnergyReservoirStorage, StorageSystemsSimulations.StorageDispatchWithReserves;
            attributes = Dict(
                "reservation" => true, "energy_target" => false,
                "cycling_limits" => false, "regularization" => false,
            ),
        ),
    )
    PSI.set_network_model!(
        template,
        PSI.NetworkModel(
            PSI.AreaBalancePowerModel; use_slacks = true, duals = [PSI.CopperPlateBalanceConstraint],
        ),
    )
    PSI.set_device_model!(template, PSY.AreaInterchange, PSI.StaticBranch)
    PSI.set_service_model!(
        template,
        PSI.ServiceModel(GenericConstraint, TermConstraint; duals = [NEMConstraintLimit]),
    )
    PSI.set_service_model!(template, PSI.ServiceModel(NEMFCASService, NEMFCASMarket))
    return template
end
