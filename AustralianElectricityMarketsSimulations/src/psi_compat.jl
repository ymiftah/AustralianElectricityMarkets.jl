# Overrides of private PowerSimulations.jl hooks. Re-check this file whenever the pinned
# PowerSimulations revision changes.

"""
    PSI._add_pwl_constraint!(container, component, variable, formulation, breakpoints, period, band_type, constraint_type)

Override of `PowerSimulations.jl`'s market-bid hook for NEM dispatch. Delegates
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


# The service models of this package, none of which folds anything into device models or carries
# initial-condition state.
const _NEM_SERVICE_MODELS = Union{
    PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
    PSI.ServiceModel{FCASService, FCASMarket},
    PSI.ServiceModel{EnergyTieBreak, TieBreakMarket},
}


"""
    PSI._modify_device_model!(devices_template, service_model::_NEM_SERVICE_MODELS, contributing_devices)

No-op override of `PowerSimulations.jl`'s private `_modify_device_model!` hook, called
unconditionally when registering a service model with contributing devices.
[`LinearFactorLimit`](@ref), [`FCASMarket`](@ref) and [`TieBreakMarket`](@ref) add no device-side
range expressions, so they have nothing to fold into the device models.

# Returns
`nothing`.
"""
function PSI._modify_device_model!(::Dict{Symbol, PSI.DeviceModel}, ::_NEM_SERVICE_MODELS, ::Vector)
    return nothing
end


"""
    PSI.get_initial_conditions_service_model(model, service_model::_NEM_SERVICE_MODELS)

Override of `PowerSimulations.jl`'s private `get_initial_conditions_service_model` hook, called for
every registered `ServiceModel` when building the sub-model PSI derives ramp and commitment initial
conditions from. The services of [`GenericConstraint`](@ref), [`FCASService`](@ref) and
[`EnergyTieBreak`](@ref) carry no such state of their own.

# Returns
A `PSI.ServiceModel` of the same service and formulation types, with default settings.
"""
function PSI.get_initial_conditions_service_model(::PSI.OperationModel, service_model::_NEM_SERVICE_MODELS)
    return PSI.ServiceModel(PSI.get_component_type(service_model), PSI.get_formulation(service_model))
end


# PSI keys these on the device type with a bare `AbstractDeviceFormulation`, so the
# `PSY.StaticInjection` method below is ambiguous for a `PSY.Generator`; the two narrower methods
# break the tie.

"""
    PSI._include_min_gen_power_in_constraint(::PSY.StaticInjection, ::PSI.ActivePowerVariable, ::AbstractNEMDispatch)

Override of `PowerSimulations.jl`'s private market-bid hook: the bid stack's first
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

Override of `PowerSimulations.jl`'s private market-bid hook: the bid stack's first
breakpoint enters the power balance as a constant rather than through an `OnVariable`.

# Returns
`true`.
"""
PSI._include_constant_min_gen_power_in_constraint(::PSY.StaticInjection, ::PSI.ActivePowerVariable, ::AbstractNEMDispatch) = true

"""
    PSI._add_variable_cost_to_objective!(container, ::PSI.ActivePowerOutVariable, component::PSY.Storage, cost_function::PSY.MarketBidCost, ::AbstractNEMDispatch)

Override of `PowerSimulations.jl`'s private market-bid hook: prices a battery's
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

Override of `PowerSimulations.jl`'s private market-bid hook: prices a battery's charge
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

Override of `PowerSimulations.jl`'s private market-bid hook: prices a scheduled load's
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

Override of `PowerSimulations.jl`'s private market-bid hook: a scheduled load has no
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
