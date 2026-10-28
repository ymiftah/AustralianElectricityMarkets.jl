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


# Whether `cost` has offer curves on the side (`decremental`). A `MarketBidCost` with none on a side
# (for example a non-scheduled load with no energy offer) contributes no cost term on it.
_has_offer_curves(cost::PSY.MarketBidCost, decremental::Bool) =
    !isnothing(decremental ? PSY.get_decremental_offer_curves(cost) : PSY.get_incremental_offer_curves(cost))

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
    _has_offer_curves(cost_function, false) && PSI.add_pwl_term!(false, container, component, cost_function, T(), V())
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
    _has_offer_curves(cost_function, true) && PSI.add_pwl_term!(true, container, component, cost_function, T(), V())
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
    _has_offer_curves(cost_function, true) && PSI.add_pwl_term!(true, container, component, cost_function, T(), V())
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


# --- Time-series parameters keyed by meta, which PSI's `add_parameters!` cannot add ---

"""
    _add_series_parameter!(container, param, D, components, ts_name, meta; axes = ()) -> PSI.ParameterContainer

Adds `param` keyed `(D, meta)` with one row per component of `components`, each valued from that
component's `ts_name` forecast over the container's time steps through
`PowerSimulations._unwrap_for_param` on the extra `axes`, with multipliers `1.0`. The rows are
registered by forecast UUID, so PowerSimulations' time-series parameter update refreshes them.

# Arguments
- `container`: the optimization container of the model being built.
- `param`: the `PSI.ParameterType` instance to add.
- `D`: the component type the parameter is keyed by.
- `components`: the components carrying a `ts_name` forecast, one row each.
- `ts_name`: the forecast name.
- `meta`: the container meta.
- `axes`: the axes between the component and time axes, `()` for a scalar parameter.

# Returns
The new parameter container.
"""
function _add_series_parameter!(
        container::PSI.OptimizationContainer, param::PSI.ParameterType, ::Type{D}, components,
        ts_name::String, meta::String; axes::Tuple = (),
    ) where {D <: PSY.Component}
    ts_type = PSI.get_default_time_series_type(container)
    settings = PSI.get_settings(container)
    interval, resolution = PSI.get_interval(settings), PSI.get_resolution(settings)
    names = PSY.get_name.(components)
    uuids = [
        string(
            IS.get_time_series_uuid(
                ts_type, c, ts_name; resolution = PSI._to_is_resolution(resolution), interval = PSI._to_is_interval(interval),
            ),
        ) for c in components
    ]
    time_steps = PSI.get_time_steps(container)
    param_container = PSI.add_param_container!(
        container, param, D, ts_type, ts_name, uuids, names, axes, time_steps; meta = meta,
    )
    attributes = PSI.get_attributes(param_container)
    jm = PSI.get_jump_model(container)
    values = PSI.get_parameter_array_data(param_container)
    multipliers = PSI.get_multiplier_array_data(param_container)
    for (i, c) in enumerate(components)
        raw = PSI.get_time_series_initial_values!(container, ts_type, c, ts_name; interval = interval, resolution = resolution)
        for t in time_steps
            PSI._set_parameter_at!(values, jm, PSI._unwrap_for_param(param, raw[t], axes), i, t)
        end
        PSI._set_multiplier_at!(multipliers, 1.0, i)
        PSI.add_component_name!(attributes, names[i], uuids[i])
    end
    return param_container
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

# An offer curve's band prices in $/MW per interval, padded with zero prices to the band axis.
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
