# Every override of, and call into, a private PowerSimulations.jl internal. Re-check this file
# whenever the pinned PowerSimulations revision changes.

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

# An offer curve's band widths in MW, padded with zero-width bands to the band axis.
function PSI._unwrap_for_param(::EnergyBandWidthParameter, curve::IS.PiecewiseStepData, expected_axs)
    x = PSY.get_x_coords(curve)
    iszero(first(x)) || throw(ArgumentError("energy offer curves must start at 0 MW, got $(first(x))."))
    widths = diff(x)
    n = length(only(expected_axs))
    length(widths) <= n || throw(ArgumentError("energy offer has $(length(widths)) bands, more than the band axis' $n."))
    return vcat(widths, zeros(n - length(widths)))
end

# An offer curve's band prices in $/MWh, padded with zero prices to the band axis.
function PSI._unwrap_for_param(::EnergyBandPriceParameter, curve::IS.PiecewiseStepData, expected_axs)
    prices = PSY.get_y_coords(curve)
    n = length(only(expected_axs))
    length(prices) <= n || throw(ArgumentError("energy offer has $(length(prices)) bands, more than the band axis' $n."))
    return vcat(prices, zeros(n - length(prices)))
end


# --- Derived series names for the NEM dispatch parameters ---

# `_get_time_series_name` resolves the parameter's series name per device, so a device's derived series
# key names the series. The device's own key is read, not the type's first device's: every device of a
# type carries the same name, which is what lets the one-name-per-type registration work.
#
# The `D <: PSY.Device` constraint is required, not decorative: without it these methods are ambiguous
# with PSI's generic `_get_time_series_name(::T, ::Component, ::DeviceModel) where {T <: ParameterType}`
# and the model build fails. Re-check the signature when the pinned fork moves.
PSI._get_time_series_name(::RampUpRateTimeSeriesParameter, device::PSY.Component, ::PSI.DeviceModel{D, B}) where {D <: PSY.Device, B <: AbstractNEMDispatch} =
    _inputs_series_name(device, :ramp_up)

PSI._get_time_series_name(::RampDownRateTimeSeriesParameter, device::PSY.Component, ::PSI.DeviceModel{D, B}) where {D <: PSY.Device, B <: AbstractNEMDispatch} =
    _inputs_series_name(device, :ramp_down)

PSI._get_time_series_name(::EnergyMaxAvailTimeSeriesParameter, device::PSY.Component, ::PSI.DeviceModel{D, B}) where {D <: PSY.Device, B <: AbstractNEMDispatch} =
    _inputs_series_name(device, :energy_availability)

PSI._get_time_series_name(::PSI.ActivePowerOutTimeSeriesParameter, device::PSY.Storage, ::PSI.DeviceModel{D, B}) where {D <: PSY.Device, B <: AbstractNEMDispatch} =
    _inputs_series_name(device, :energy_availability)

PSI._get_time_series_name(::PSI.ActivePowerInTimeSeriesParameter, device::PSY.Storage, ::PSI.DeviceModel{D, B}) where {D <: PSY.Device, B <: AbstractNEMDispatch} =
    _inputs_series_name(device, :energy_availability_decremental)


# --- Stock parameter updates and the private PowerSimulations.jl calls behind them ---

"""
    _psi_set_param_value_at!(parent_param, value, i, t)

Writes `value` into row `i`, column `t` of `parent_param`, through PowerSimulations.jl's private
`_set_param_value_at!`.

# Arguments
- `parent_param`: the parameter's data array.
- `value`: the value to write, typed as the array's element.
- `i`: the row of the device.
- `t`: the column of the time step.

# Returns
`nothing`.
"""
function _psi_set_param_value_at!(parent_param, value, i::Integer, t::Integer)
    PSI._set_param_value_at!(parent_param, value, i, t)
    return
end

"""
    _psi_apply_coefficient_targets!(param)

Rewrites the registered constraint coefficients of the coefficient parameter `param`, through
PowerSimulations.jl's private `_apply_coefficient_targets!`.

# Arguments
- `param`: the `PowerSimulations.ParameterContainer` of a constraint-coefficient parameter.

# Returns
`nothing`.
"""
function _psi_apply_coefficient_targets!(param)
    PSI._apply_coefficient_targets!(param)
    return
end

# Runs the pinned fork's stock update for `key`. A coefficient parameter's stock method also applies its targets.
function _stock_state_update!(
        container::PSI.OptimizationContainer, model::PSI.OperationModel,
        key::PSI.ParameterKey{<:PSI.ConstraintCoefficientParameter, <:PSY.Component}, input::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    invoke(
        PSI.update_container_parameter_values!,
        Tuple{
            PSI.OptimizationContainer, PSI.OperationModel,
            PSI.ParameterKey{<:PSI.ConstraintCoefficientParameter, <:PSY.Component}, PSI.DatasetContainer{PSI.InMemoryDataset},
        },
        container, model, key, input,
    )
    return
end

# Runs the pinned fork's stock update for a time-series `key`. Only time-series and constraint-coefficient
# parameters reach it, so an objective or cost parameter has no method here.
function _stock_state_update!(
        container::PSI.OptimizationContainer, model::PSI.OperationModel,
        key::PSI.ParameterKey{<:PSI.TimeSeriesParameter, <:PSY.Component}, input::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    invoke(
        PSI.update_container_parameter_values!,
        Tuple{
            PSI.OptimizationContainer, PSI.OperationModel,
            PSI.ParameterKey{<:PSI.ParameterType, <:PSY.Component}, PSI.DatasetContainer{PSI.InMemoryDataset},
        },
        container, model, key, input,
    )
    return
end
