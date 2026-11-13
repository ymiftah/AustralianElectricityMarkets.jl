#! format: off
PSI.get_variable_binary(::PSI.ActivePowerOutVariable, ::Type{<:PSY.Storage}, ::AbstractNEMDispatch) = false

PSI.get_variable_binary(::PSI.ActivePowerInVariable, ::Type{<:PSY.Storage}, ::AbstractNEMDispatch) = false

PSI.get_variable_multiplier(::PSI.ActivePowerOutVariable, ::Type{<:PSY.Storage}, ::AbstractNEMDispatch) = 1.0

PSI.get_variable_multiplier(::PSI.ActivePowerInVariable, ::Type{<:PSY.Storage}, ::AbstractNEMDispatch) = -1.0

PSI.get_variable_lower_bound(::PSI.ActivePowerOutVariable, ::PSY.Storage, ::AbstractNEMDispatch) = 0.0

PSI.get_variable_lower_bound(::PSI.ActivePowerInVariable, ::PSY.Storage, ::AbstractNEMDispatch) = 0.0

PSI.get_variable_upper_bound(::PSI.ActivePowerOutVariable, ::PSY.Storage, ::AbstractNEMDispatch) = nothing

PSI.get_variable_upper_bound(::PSI.ActivePowerInVariable, ::PSY.Storage, ::AbstractNEMDispatch) = nothing

# The energy bid MAXAVAIL series are stored in MW.
PSI.get_multiplier_value(::PSI.ActivePowerOutTimeSeriesParameter, d::PSY.Storage, ::AbstractNEMDispatch) = 1 / PSY.get_system_base_power(d)

PSI.get_multiplier_value(::PSI.ActivePowerInTimeSeriesParameter, d::PSY.Storage, ::AbstractNEMDispatch) = 1 / PSY.get_system_base_power(d)

#! format: on

"""
    PSI.get_default_time_series_names(::Type{<:PSY.Storage}, ::Type{<:AbstractNEMDispatch})

Registers the time series [`AbstractNEMDispatch`](@ref) reads as parameters for a battery: the
ramp parameters and the generation and consumption energy bid `MAXAVAIL` series. The initial-power
parameter is added explicitly from the build's first-solve seed series. Both availability limits carry priced violations on the
generation and consumption axes. Batteries register no `"max_active_power"` series.

# Returns
A `Dict` mapping each `PowerSimulations.TimeSeriesParameter` type to its series name.
"""
function PSI.get_default_time_series_names(
        ::Type{<:PSY.Storage},
        ::Type{<:AbstractNEMDispatch},
    )
    return Dict{Type{<:PSI.TimeSeriesParameter}, String}(
        RampRateTimeSeriesParameter => NEM_SERIES.ramp_up_rate,
        PSI.ActivePowerOutTimeSeriesParameter => _max_avail_series_name(OfferSide.GEN),
        PSI.ActivePowerInTimeSeriesParameter => _max_avail_series_name(OfferSide.LOAD),
    )
end


"""
    PSI.construct_device!(container, sys, ::PSI.ArgumentConstructStage, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_model) where {T <: PSY.Storage}

Argument stage for a battery under [`AbstractNEMDispatch`](@ref): the per-direction active
power variables, the ramp parameters, the raw availability
parameters, the offer-total violation variables, and the device's net
contribution to the active power balance.

# Returns
`nothing`.
"""
function PSI.construct_device!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ArgumentConstructStage,
        model::PSI.DeviceModel{T, D},
        network_model::PSI.NetworkModel{<:PM.AbstractActivePowerModel},
    ) where {T <: PSY.Storage, D <: AbstractNEMDispatch}
    devices = PSI.get_available_components(model, sys)

    _check_energy_limit_series(sys, model, PSI.get_initial_time(container), length(PSI.get_time_steps(container)))

    PSI.add_variables!(container, PSI.ActivePowerOutVariable, devices, D())
    PSI.add_variables!(container, PSI.ActivePowerInVariable, devices, D())
    _add_device_unit_slacks!(container, EnergyLimitMaxAvailOutVariant(), devices)
    _add_device_unit_slacks!(container, EnergyLimitMaxAvailInVariant(), devices)

    _add_ramp_rate_parameters!(container, devices, model)
    for param in _storage_parameters(D)
        haskey(PSI.get_time_series_names(model), param) || continue
        PSI.add_parameters!(container, param, devices, model)
    end
    PSI.add_parameters!(
        container, InitialPowerTimeSeriesParameter, devices, model;
        time_series_name = NEM_STATE_INPUT_SERIES.initial_mw,
    )

    _add_fixed_load_arguments!(container, devices, model)

    for variant in _ENERGY_OFFER_SLACK_VARIANTS
        _add_energy_offer_slack_variables!(container, variant, devices)
    end
    PSI.add_to_expression!(
        container,
        PSI.ActivePowerBalance,
        PSI.ActivePowerOutVariable,
        devices,
        model,
        network_model,
    )
    PSI.add_to_expression!(
        container,
        PSI.ActivePowerBalance,
        PSI.ActivePowerInVariable,
        devices,
        model,
        network_model,
    )

    PSI.add_feedforward_arguments!(container, model, devices)
    return
end


"""
    PSI.construct_device!(container, sys, ::PSI.ModelConstructStage, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_model) where {T <: PSY.Storage}

Model stage for a battery under [`AbstractNEMDispatch`](@ref): the elastic directional availability
envelope, the net ramp constraint and the energy offer bands and their objective.

# Returns
`nothing`.
"""
function PSI.construct_device!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ModelConstructStage,
        model::PSI.DeviceModel{T, D},
        network_model::PSI.NetworkModel{<:PM.AbstractActivePowerModel},
    ) where {T <: PSY.Storage, D <: AbstractNEMDispatch}
    devices = PSI.get_available_components(model, sys)

    _add_energy_limit_rows!(container, EnergyLimitMaxAvailOutVariant(), PSI.ActivePowerOutVariable, devices, model, network_model)
    _add_energy_limit_rows!(container, EnergyLimitMaxAvailInVariant(), PSI.ActivePowerInVariable, devices, model, network_model)
    PSI.add_constraints!(container, PSI.RampConstraint, PSI.ActivePowerOutVariable, devices, model, network_model)
    PSI.add_constraints!(container, NEMUnitConstraint, devices, model, network_model)

    PSI.add_feedforward_constraints!(container, model, devices)
    PSI.objective_function!(container, devices, model, PSI.get_network_formulation(network_model))
    PSI.add_constraint_dual!(container, sys, model)
    return
end


"""
    PSI.objective_function!(container, devices, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_formulation) where {T <: PSY.Storage}

Prices a battery's discharge on its `GEN` energy offer bands against
`PowerSimulations.ActivePowerOutVariable` and its charge on its `LOAD` energy offer bands against
`PowerSimulations.ActivePowerInVariable`. Throws `ArgumentError` through `_check_energy_offer_sides`
for a battery with an energy offer on one side only.

# Returns
`nothing`.
"""
function PSI.objective_function!(
        container::PSI.OptimizationContainer,
        devices::IS.FlattenIteratorWrapper{T},
        model::PSI.DeviceModel{T, D},
        ::Type{<:PM.AbstractPowerModel},
    ) where {T <: PSY.Storage, D <: AbstractNEMDispatch}
    _check_energy_offer_sides(devices)
    foreach(side -> _add_energy_offer_bands!(container, devices, model, side), _energy_offer_sides(T))
    _add_device_unit_slack_costs!(container, EnergyLimitMaxAvailOutVariant(), devices)
    _add_device_unit_slack_costs!(container, EnergyLimitMaxAvailInVariant(), devices)
    _add_fixed_load_costs!(container, devices, T)
    for variant in _ENERGY_OFFER_SLACK_VARIANTS
        _add_energy_offer_slack_costs!(container, variant, devices)
    end
    return
end


# Both formulations read live raw availability, independently of their ramp reference.
_storage_parameters(::Type{<:AbstractNEMDispatch}) = (
    PSI.ActivePowerOutTimeSeriesParameter, PSI.ActivePowerInTimeSeriesParameter,
)


"""
    PSI.add_constraints!(container, ::Type{PSI.RampConstraint}, ::Type{PSI.ActivePowerOutVariable}, devices, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_model) where {T <: PSY.Storage}

Holds each battery's net `Out - In` within its per-interval ramp rates of the base its
formulation measures against, through [`_add_nem_ramp_constraints!`](@ref), so a net ramp
envelope that conflicts with the per-direction bounds is violated at the unit ramp CVP instead of
making the model infeasible.

# Returns
`nothing`.
"""
function PSI.add_constraints!(
        container::PSI.OptimizationContainer,
        ::Type{PSI.RampConstraint},
        ::Type{PSI.ActivePowerOutVariable},
        devices::IS.FlattenIteratorWrapper{T},
        ::PSI.DeviceModel{T, D},
        ::PSI.NetworkModel{<:PM.AbstractPowerModel},
    ) where {T <: PSY.Storage, D <: AbstractNEMDispatch}
    out = PSI.get_variable(container, PSI.ActivePowerOutVariable(), T)
    in_ = PSI.get_variable(container, PSI.ActivePowerInVariable(), T)
    _add_nem_ramp_constraints!(
        container, T, devices, (name, t) -> out[name, t] - in_[name, t],
        names -> _storage_ramp_base_accessor(container, D, T, names, out, in_),
    )
    return
end


_storage_ramp_base_accessor(container, ::Type{NEMReplayDispatch}, ::Type{T}, names, out, in_) where {T <: PSY.Storage} =
    _ramp_base_accessor(container, NEMReplayDispatch, T, names, nothing)
