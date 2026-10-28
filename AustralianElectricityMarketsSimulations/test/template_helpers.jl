# Private test-only `PSI.ProblemTemplate` builders for the PSCB fixture, not part of the
# package's public API.

import PowerSimulations as PSI
import PowerSystems as PSY
import HydroPowerSimulations

"""
    _decision_model(args...; mpc = 20_000.0, kwargs...)

`PSI.DecisionModel` with the `"market_price_cap"` settings entry set, for PSCB fixtures dated outside
`AustralianElectricityMarkets.MARKET_PRICE_CAP_BY_FINANCIAL_YEAR` whose area-balance slack still needs a Market Price Cap.
"""
function _decision_model(args...; mpc = 20_000.0, kwargs...)
    model = PSI.DecisionModel(args...; kwargs...)
    PSI.get_ext(PSI.get_settings(model))["market_price_cap"] = mpc
    return model
end

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

# Buildable subset of every `GenericConstraint` in `sys` for `template`.
_buildable_gcs(sys, template; kwargs...) = AEMS._filter_buildable_generic_constraints(
    sys, template, PSY.get_components(GenericConstraint, sys); kwargs...,
)

# Sundance's 100 MW floor exceeds fixture demand under no-commitment dispatch; zero every
# `ThermalStandard` floor before building an `augmented_pscb_system()` template.
function _fix_thermal_floor!(sys)
    for gen in PSY.get_components(PSY.ThermalStandard, sys)
        limits = PSY.get_active_power_limits(gen)
        PSY.set_active_power_limits!(gen, (min = 0.0, max = limits.max))
    end
    return
end


# `name => (DateTime => raw dual)` of every `NEMConstraintLimit` in `results`.
function stock_gc_duals(results)
    read(k) = results isa PSI.SimulationProblemResults ? only(values(PSI.read_realized_duals(results, [k]))) : PSI.read_dual(results, k)
    return Dict(
        k.meta => Dict(r.DateTime => r.value for r in eachrow(read(k)))
            for k in PSI.list_dual_keys(results) if PSI.IS.Optimization.get_entry_type(k) === NEMConstraintLimit
    )
end

# The exception `f()` throws, or `nothing` if it returns normally.
_caught(f) = try
    f(); nothing
catch e
    e
end
