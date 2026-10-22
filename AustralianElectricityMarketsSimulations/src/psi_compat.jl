# Every PowerSimulations.jl override this package declares lives here, each stating the PSI
# version it was written against. Re-check this file on every PSI upgrade.

"""
    PSI._add_pwl_constraint!(container, component, variable, formulation, breakpoints, period, band_type, constraint_type)

Override of the pinned PowerSimulations 0.38.4 market-bid hook for NEM dispatch. Delegates
energy dispatch-to-band constraints to the typed elastic-offer formulation.

# Returns
`nothing`.
"""
function PSI._add_pwl_constraint!(
        container::PSI.OptimizationContainer, component::T, variable::U, formulation::D,
        breakpoints::Vector{<:PSI.JuMPOrFloat}, period::Int, ::Type{V}, ::Type{W},
    ) where {
        T <: PSY.StaticInjection, U <: PSI.VariableType, D <: AbstractNEMDispatch,
        V <: PSI.AbstractPiecewiseLinearBlockOffer, W <: PSI.AbstractPiecewiseLinearBlockOfferConstraint,
    }
    PSI.add_constraints!(container, W, component, variable, formulation, breakpoints, period, V)
    return
end


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

"""
    PSI._modify_device_model!(devices_template, ::PSI.ServiceModel{EnergyTieBreak, TieBreakMarket}, contributing_devices)

No-op override of `PowerSimulations.jl` 0.38.4's private `_modify_device_model!` hook, called
unconditionally when registering a service model with contributing devices. [`TieBreakMarket`](@ref)
adds no device-side range expressions, so it has nothing to fold into the device models.

# Returns
`nothing`.
"""
function PSI._modify_device_model!(
        ::Dict{Symbol, PSI.DeviceModel},
        ::PSI.ServiceModel{EnergyTieBreak, TieBreakMarket},
        ::Vector,
    )
    return nothing
end

"""
    PSI.get_initial_conditions_service_model(model, service_model::PSI.ServiceModel{EnergyTieBreak, TieBreakMarket})

The service model PSI's initial-conditions sub-model uses for an [`EnergyTieBreak`](@ref).

# Returns
`PSI.ServiceModel(EnergyTieBreak, TieBreakMarket)`.
"""
function PSI.get_initial_conditions_service_model(
        ::PSI.OperationModel,
        ::PSI.ServiceModel{EnergyTieBreak, TieBreakMarket},
    )
    return PSI.ServiceModel(EnergyTieBreak, TieBreakMarket)
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
PSI._include_min_gen_power_in_constraint(::PSY.ControllableLoad, ::PSI.ActivePowerVariable, ::AbstractNEMDispatch) = false

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
    PSI._add_variable_cost_to_objective!(container, ::PSI.ActivePowerVariable, component::PSY.ControllableLoad, cost_function::PSY.MarketBidCost, ::AbstractNEMDispatch)

Override of `PowerSimulations.jl` 0.38.4's private market-bid hook: prices a scheduled load's
consumption on its decremental (`"decremental_variable_cost"`) offer curve, so a cleared load band
lowers the objective.

# Returns
`nothing`.
"""
function PSI._add_variable_cost_to_objective!(
        container::PSI.OptimizationContainer,
        ::T,
        component::PSY.ControllableLoad,
        cost_function::PSY.MarketBidCost,
        ::V,
    ) where {T <: PSI.ActivePowerVariable, V <: AbstractNEMDispatch}
    PSI.add_pwl_term!(true, container, component, cost_function, T(), V())
    return
end

"""
    PSI._add_vom_cost_to_objective!(container, ::PSI.ActivePowerVariable, component::PSY.ControllableLoad, op_cost::PSY.MarketBidCost, ::AbstractNEMDispatch)

Override of `PowerSimulations.jl` 0.38.4's private market-bid hook: a scheduled load has no
incremental offer curve to read a variable O&M cost from, so none is added.

# Returns
`nothing`.
"""
function PSI._add_vom_cost_to_objective!(
        ::PSI.OptimizationContainer,
        ::PSI.ActivePowerVariable,
        ::PSY.ControllableLoad,
        ::PSY.MarketBidCost,
        ::AbstractNEMDispatch,
    )
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
year, or the `"market_price_cap"` entry of the model's settings `ext`
([`_container_market_price_cap`](@ref)), in `\$/MW` per dispatch interval. Throws for a financial
year absent from `MARKET_PRICE_CAP_BY_FINANCIAL_YEAR` with no override. `AreaPTDFPowerModel` keeps
PSI's flat `BALANCE_SLACK_COST`.

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
    time_steps = PSI.get_time_steps(container)
    _add_mpc_penalty!(container, variable_dn, areas, time_steps, AREA_BALANCE_CVP_FACTOR)
    _add_mpc_penalty!(container, variable_up, areas, time_steps, AREA_BALANCE_CVP_FACTOR)
    return nothing
end


"""
    PSI._update_parameter_values!(parameter_array, ::MarketPriceCapPenaltyParameter, parameter_multiplier, attributes, ::Type{PSY.Area}, model, input)

Override of `PowerSimulations.jl` 0.38.4's private objective-parameter update for the
[`MarketPriceCapPenaltyParameter`](@ref) registered on `PSY.Area`, which has no device model for
the generic method to look up. Re-prices every Market Price Cap penalty slack of the model for the
step's window.

# Returns
`nothing`.
"""
function PSI._update_parameter_values!(
        ::PSI.DenseAxisArray, ::MarketPriceCapPenaltyParameter, ::PSI.JuMPFloatArray,
        ::PSI.CostFunctionAttributes, ::Type{PSY.Area}, model::PSI.DecisionModel,
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    container = PSI.get_optimization_container(model)
    PSI.is_synchronized(container) && error(
        "Cannot update MarketPriceCapPenaltyParameter on a synchronized container; objective expressions would be double-counted",
    )
    _reprice_mpc_penalties!(container, PSI.get_current_time(model), last(PSI.get_time_steps(container)))
    return
end
