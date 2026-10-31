# Every override of, and call into, a private PowerSimulations.jl internal. Re-check this file
# whenever the pinned PowerSimulations revision changes.

"""
    PSI._add_pwl_constraint!(container, component, variable, formulation, breakpoints, period, band_type, constraint_type)

Override of `PowerSimulations.jl`'s market-bid hook for NEM dispatch: links dispatch to its cleared
energy bands with separately priced positive and negative mismatches
([`EnergyOfferSurplusSlack`](@ref), [`EnergyOfferDeficitSlack`](@ref) and their decremental
counterparts). Keeps each band's live width bound, and the first breakpoint as a constant offset,
so no `OnVariable` is required.

# Returns
`nothing`.
"""
function PSI._add_pwl_constraint!(
        container::PSI.OptimizationContainer, component::T, ::U, ::D,
        breakpoints::Vector{<:PSI.JuMPOrFloat}, period::Int, ::Type{V}, ::Type{W},
    ) where {
        T <: PSY.StaticInjection, U <: PSI.VariableType, D <: AbstractNEMDispatch,
        V <: PSI.AbstractPiecewiseLinearBlockOffer, W <: PSI.AbstractPiecewiseLinearBlockOfferConstraint,
    }
    jm = PSI.get_jump_model(container)
    power = PSI.get_variable(container, U(), T)
    bands = PSI.get_variable(container, V(), T)
    name = PSY.get_name(component)
    rows = PSI.lazy_container_addition!(container, W(), T, axes(power)...)
    above_type, below_type = _energy_offer_slacks(V)
    above = PSI.get_variable(container, above_type(), T)[name, period]
    below = PSI.get_variable(container, below_type(), T)[name, period]
    offset = PSI.jump_fixed_value(first(breakpoints))::Float64
    length(breakpoints) > 1 || throw(ArgumentError("energy offers require at least one band"))
    rows[name, period] = JuMP.@constraint(
        jm, power[name, period] == offset +
            sum(bands[name, k, period] for k in 1:(length(breakpoints) - 1)) + above - below
    )
    for k in 1:(length(breakpoints) - 1)
        JuMP.@constraint(jm, bands[name, k, period] <= breakpoints[k + 1] - breakpoints[k])
    end
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


# Whether `cost` has offer curves on the side (`decremental`).
function _has_offer_curves(cost::PSY.MarketBidCost, decremental::Bool)
    curves = decremental ? PSY.get_decremental_offer_curves(cost) : PSY.get_incremental_offer_curves(cost)
    return !isnothing(curves)
end

# Whether `cost` has no energy offer curves on either side, as for a device bidding only FCAS services.
function _is_service_only(cost::PSY.MarketBidCost)
    return !_has_offer_curves(cost, false) && !_has_offer_curves(cost, true)
end

# Adds the energy offer term on the side (`decremental`). A service-only cost adds nothing, and a cost
# with a curve only on the other side throws, rather than pricing this side at zero.
function _add_energy_offer_term!(
        decremental::Bool, container::PSI.OptimizationContainer, component::PSY.Component,
        cost::PSY.MarketBidCost, variable::PSI.VariableType, formulation::AbstractNEMDispatch,
    )
    if _has_offer_curves(cost, decremental)
        PSI.add_pwl_term!(decremental, container, component, cost, variable, formulation)
    elseif !_is_service_only(cost)
        side = decremental ? "LOAD" : "GEN"
        throw(
            ArgumentError(
                "$(PSY.get_name(component)): the MarketBidCost has energy offers on the other side but no $side " *
                    "offer curve, so this side would be priced at zero. Add the $side offer curve or remove the other side's.",
            ),
        )
    end
    return
end

"""
    PSI._add_variable_cost_to_objective!(container, ::PSI.ActivePowerOutVariable, component::PSY.Storage, cost_function::PSY.MarketBidCost, ::AbstractNEMDispatch)

Override of `PowerSimulations.jl`'s private market-bid hook: prices a battery's
discharge on its incremental (`"variable_cost"`) offer curve. A service-only cost adds nothing;
a cost with only a decremental curve throws.

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
    _add_energy_offer_term!(false, container, component, cost_function, T(), V())
    return
end

"""
    PSI._add_variable_cost_to_objective!(container, ::PSI.ActivePowerInVariable, component::PSY.Storage, cost_function::PSY.MarketBidCost, ::AbstractNEMDispatch)

Override of `PowerSimulations.jl`'s private market-bid hook: prices a battery's charge
on its decremental (`"decremental_variable_cost"`) offer curve, so a load bid band lowers the
objective when cleared. A service-only cost adds nothing; a cost with only an incremental curve throws.

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
    _add_energy_offer_term!(true, container, component, cost_function, T(), V())
    return
end

"""
    PSI._add_variable_cost_to_objective!(container, ::PSI.ActivePowerVariable, component::PSY.ControllableLoad, cost_function::PSY.MarketBidCost, ::AbstractNEMDispatch)

Override of `PowerSimulations.jl`'s private market-bid hook: prices a scheduled load's
consumption on its decremental (`"decremental_variable_cost"`) offer curve, so a cleared load band
lowers the objective. A service-only cost adds nothing; a cost with only an incremental curve throws.

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
    _add_energy_offer_term!(true, container, component, cost_function, T(), V())
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


# --- Parameter element unwrapping for AEMSim's structured series ---

# An FCAS effective offer `(max_avail, enablement_min, enablement_max, upper_slope, lower_slope,
# band widths...)` split across its parameters.
function PSI._unwrap_for_param(::FCASOfferLimitParameter, v::NTuple{15, Float64}, _)
    return [v[1], v[2], v[3]]
end
function PSI._unwrap_for_param(::FCASUpperSlopeParameter, v::NTuple{15, Float64}, _)
    return v[4]
end
function PSI._unwrap_for_param(::FCASLowerSlopeParameter, v::NTuple{15, Float64}, _)
    return v[5]
end
function PSI._unwrap_for_param(::FCASBandWidthParameter, v::NTuple{15, Float64}, _)
    return collect(v[6:15])
end
function PSI._unwrap_for_param(::FCASRampingLimitParameter, v::NTuple{2, Float64}, _)
    return [v[1], v[2]]
end

# An offer curve's band widths in MW, padded with zero-width bands to the band axis.
function PSI._unwrap_for_param(::MNSPBandWidthParameter, curve::IS.PiecewiseStepData, expected_axs)
    widths = diff(PSY.get_x_coords(curve))
    n = length(only(expected_axs))
    length(widths) <= n || throw(ArgumentError("MNSP offer has $(length(widths)) bands, more than the band axis' $n."))
    return vcat(widths, zeros(n - length(widths)))
end

# An offer curve's band prices in $/MWh, padded with zero prices to the band axis.
function PSI._unwrap_for_param(::FCASBandPriceParameter, curve::IS.PiecewiseStepData, expected_axs)
    prices = PSY.get_y_coords(curve)
    n = length(only(expected_axs))
    length(prices) <= n || throw(ArgumentError("FCAS offer has $(length(prices)) bands, more than the band axis' $n."))
    return vcat(prices, zeros(n - length(prices)))
end

# An offer curve's band prices in $/MWh, padded with zero prices to the band axis.
function PSI._unwrap_for_param(::MNSPBandPriceParameter, curve::IS.PiecewiseStepData, expected_axs)
    prices = PSY.get_y_coords(curve)
    n = length(only(expected_axs))
    length(prices) <= n || throw(ArgumentError("MNSP offer has $(length(prices)) bands, more than the band axis' $n."))
    return vcat(prices, zeros(n - length(prices)))
end
