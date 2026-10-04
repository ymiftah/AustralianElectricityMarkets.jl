# Every PowerSimulations.jl override this package declares lives here, each stating the PSI
# version it was written against. Re-check this file on every PSI upgrade.

"""
    PSI._modify_device_model!(devices_template, ::PSI.ServiceModel{GenericConstraint, LinearFactorLimit}, contributing_devices)

No-op override of `PowerSimulations.jl` 0.38.4's private `_modify_device_model!` hook, called
unconditionally when registering a service model with contributing devices. [`LinearFactorLimit`](@ref)
adds no device-side range expressions, so it has nothing to fold into the device models.

# Returns
`nothing`.
"""
function PSI._modify_device_model!(
        ::Dict{Symbol, PSI.DeviceModel},
        ::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
        ::Vector,
    )
    return nothing
end

"""
    PSI._modify_device_model!(devices_template, ::PSI.ServiceModel{FCASService, FCASMarket}, contributing_devices)

No-op override of `PowerSimulations.jl` 0.38.4's private `_modify_device_model!` hook, called
unconditionally when registering a service model with contributing devices. [`FCASMarket`](@ref)
adds no device-side range expressions, so it has nothing to fold into the device models.

# Returns
`nothing`.
"""
function PSI._modify_device_model!(
        ::Dict{Symbol, PSI.DeviceModel},
        ::PSI.ServiceModel{FCASService, FCASMarket},
        ::Vector,
    )
    return nothing
end

"""
    PSI.get_initial_conditions_service_model(model, service_model::PSI.ServiceModel{GenericConstraint, LinearFactorLimit})

No-op override of `PowerSimulations.jl` 0.38.4's private `get_initial_conditions_service_model`
hook, called for every registered `ServiceModel` when building the sub-model PSI derives
ramp/commitment initial conditions from. [`LinearFactorLimit`](@ref) carries no ramp/commitment
state of its own to initialize.

# Returns
`PSI.ServiceModel(GenericConstraint, LinearFactorLimit)`.
"""
function PSI.get_initial_conditions_service_model(
        ::PSI.OperationModel,
        ::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
    )
    return PSI.ServiceModel(GenericConstraint, LinearFactorLimit)
end

"""
    PSI.get_initial_conditions_service_model(model, service_model::PSI.ServiceModel{FCASService, FCASMarket})

The service model PSI's initial-conditions sub-model uses for an [`FCASService`](@ref).

# Returns
`PSI.ServiceModel(FCASService, FCASMarket)`.
"""
function PSI.get_initial_conditions_service_model(
        ::PSI.OperationModel,
        ::PSI.ServiceModel{FCASService, FCASMarket},
    )
    return PSI.ServiceModel(FCASService, FCASMarket)
end

# PSI 0.38.4 keys these on the device type with a bare `AbstractDeviceFormulation`, so the
# `PSY.StaticInjection` method below is ambiguous for a `PSY.Generator`; the two narrower methods
# break the tie.

"""
    PSI._include_min_gen_power_in_constraint(::PSY.StaticInjection, ::PSI.ActivePowerVariable, ::AbstractNEMDispatch)

Override of `PowerSimulations.jl` 0.38.4's private market-bid hook: the bid stack's first
breakpoint contributes no minimum-generation offset, so no `OnVariable` is required.

# Returns
`false`.
"""
PSI._include_min_gen_power_in_constraint(::PSY.StaticInjection, ::PSI.ActivePowerVariable, ::AbstractNEMDispatch) = false
PSI._include_min_gen_power_in_constraint(::PSY.Generator, ::PSI.ActivePowerVariable, ::AbstractNEMDispatch) = false
PSI._include_min_gen_power_in_constraint(::PSY.RenewableDispatch, ::PSI.ActivePowerVariable, ::AbstractNEMDispatch) = false

"""
    PSI._include_constant_min_gen_power_in_constraint(::PSY.StaticInjection, ::PSI.ActivePowerVariable, ::AbstractNEMDispatch)

Override of `PowerSimulations.jl` 0.38.4's private market-bid hook: the bid stack's first
breakpoint enters the power balance as a constant rather than through an `OnVariable`.

# Returns
`true`.
"""
PSI._include_constant_min_gen_power_in_constraint(::PSY.StaticInjection, ::PSI.ActivePowerVariable, ::AbstractNEMDispatch) = true

"""
    PSI._add_variable_cost_to_objective!(container, ::PSI.ActivePowerOutVariable, component::PSY.Storage, cost_function::PSY.MarketBidCost, ::AbstractNEMDispatch)

Override of `PowerSimulations.jl` 0.38.4's private market-bid hook: prices a battery's
discharge on its incremental (`"variable_cost"`) offer curve.

# Returns
`nothing`.
"""
function PSI._add_variable_cost_to_objective!(
        container::PSI.OptimizationContainer,
        ::T,
        component::PSY.Storage,
        cost_function::PSY.MarketBidCost,
        ::V,
    ) where {T <: PSI.ActivePowerOutVariable, V <: AbstractNEMDispatch}
    PSI.add_pwl_term!(false, container, component, cost_function, T(), V())
    return
end

"""
    PSI._add_variable_cost_to_objective!(container, ::PSI.ActivePowerInVariable, component::PSY.Storage, cost_function::PSY.MarketBidCost, ::AbstractNEMDispatch)

Override of `PowerSimulations.jl` 0.38.4's private market-bid hook: prices a battery's charge
on its decremental (`"decremental_variable_cost"`) offer curve, so a load bid band lowers the
objective when cleared.

# Returns
`nothing`.
"""
function PSI._add_variable_cost_to_objective!(
        container::PSI.OptimizationContainer,
        ::T,
        component::PSY.Storage,
        cost_function::PSY.MarketBidCost,
        ::V,
    ) where {T <: PSI.ActivePowerInVariable, V <: AbstractNEMDispatch}
    PSI.add_pwl_term!(true, container, component, cost_function, T(), V())
    return
end

"""
    AREA_BALANCE_CVP_FACTOR

CVP factor (150) of AEMO's Regional Energy Demand Supply Balance constraint (`DeficitGen` and
`SurplusGen`), items 22 and 23 of the *Schedule of Constraint Violation Penalty Factors* v8.0.
"""
const AREA_BALANCE_CVP_FACTOR = 150.0

"""
    PSI.objective_function!(container, sys, network_model::PSI.NetworkModel{PSI.AreaBalancePowerModel})

Override of `PowerSimulations.jl` 0.38.4's `AreaBalancePowerModel` slack objective, which prices
`SystemBalanceSlackUp`/`SystemBalanceSlackDown` at the fixed `BALANCE_SLACK_COST`. Prices each
slack at [`AREA_BALANCE_CVP_FACTOR`](@ref) times the Market Price Cap of the interval's financial
year ([`_published_mpc`](@ref)), in `\$/MW` per dispatch interval. An interval in a financial year
absent from `MARKET_PRICE_CAP_BY_FINANCIAL_YEAR` keeps PSI's `BALANCE_SLACK_COST`.

# Returns
`nothing`.
"""
function PSI.objective_function!(
        container::PSI.OptimizationContainer, sys::PSY.System,
        network_model::PSI.NetworkModel{PSI.AreaBalancePowerModel},
    )
    variable_up = PSI.get_variable(container, PSI.SystemBalanceSlackUp(), PSY.Area)
    variable_dn = PSI.get_variable(container, PSI.SystemBalanceSlackDown(), PSY.Area)
    areas = PSY.get_name.(PSI.get_available_components(network_model, PSY.Area, sys))
    resolution = PSI.get_resolution(container)
    initial_time = PSI.get_initial_time(container)
    base_power = PSI.get_base_power(container)
    for t in PSI.get_time_steps(container)
        mpc = _published_mpc(initial_time + resolution * (t - 1))
        coefficient = isnothing(mpc) ? PSI.BALANCE_SLACK_COST :
            base_power * interval_cost_coefficient(AREA_BALANCE_CVP_FACTOR * mpc, resolution)
        for n in areas
            PSI.add_to_objective_invariant_expression!(container, (variable_dn[n, t] + variable_up[n, t]) * coefficient)
        end
    end
    return nothing
end
