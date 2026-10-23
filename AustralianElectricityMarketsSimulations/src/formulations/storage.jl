#! format: off
PSI.get_variable_binary(::PSI.ActivePowerOutVariable, ::Type{<:PSY.Storage}, ::AbstractNEMDispatch) = false

PSI.get_variable_binary(::PSI.ActivePowerInVariable, ::Type{<:PSY.Storage}, ::AbstractNEMDispatch) = false

PSI.get_variable_multiplier(::PSI.ActivePowerOutVariable, ::Type{<:PSY.Storage}, ::AbstractNEMDispatch) = 1.0

PSI.get_variable_multiplier(::PSI.ActivePowerInVariable, ::Type{<:PSY.Storage}, ::AbstractNEMDispatch) = -1.0

PSI.get_variable_lower_bound(::PSI.ActivePowerOutVariable, ::PSY.Storage, ::AbstractNEMDispatch) = 0.0

PSI.get_variable_lower_bound(::PSI.ActivePowerInVariable, ::PSY.Storage, ::AbstractNEMDispatch) = 0.0

PSI.get_variable_upper_bound(::PSI.ActivePowerOutVariable, ::PSY.Storage, ::AbstractNEMDispatch) = nothing

PSI.get_variable_upper_bound(::PSI.ActivePowerInVariable, ::PSY.Storage, ::AbstractNEMDispatch) = nothing

PSI.get_multiplier_value(::PSI.ActivePowerOutTimeSeriesParameter, ::PSY.Storage, ::AbstractNEMDispatch) = 1.0

PSI.get_multiplier_value(::PSI.ActivePowerInTimeSeriesParameter, ::PSY.Storage, ::AbstractNEMDispatch) = 1.0


PSI.initial_condition_default(::PSI.DevicePower, d::PSY.Storage, ::AbstractNEMDispatch) = max(PSY.get_active_power(d), 0.0)

PSI.initial_condition_variable(::PSI.DevicePower, ::PSY.Storage, ::AbstractNEMDispatch) = PSI.ActivePowerOutVariable()

PSI.initial_condition_default(::StorageInputDevicePower, d::PSY.Storage, ::AbstractNEMDispatch) = max(-PSY.get_active_power(d), 0.0)

PSI.initial_condition_variable(::StorageInputDevicePower, ::PSY.Storage, ::AbstractNEMDispatch) = PSI.ActivePowerInVariable()

#! format: on

"""
    PSI.get_default_time_series_names(::Type{<:PSY.Storage}, ::Type{<:AbstractNEMDispatch})

Registers the time series [`AbstractNEMDispatch`](@ref) reads as parameters for a battery: the
ramp and initial-power series, and the raw generation and consumption energy offer availability. Both availability limits
carry priced violations on the generation and consumption axes. Batteries register no `"max_active_power"` series.

# Returns
A `Dict` mapping each `PowerSimulations.TimeSeriesParameter` type to its series name.
"""
function PSI.get_default_time_series_names(
        ::Type{<:PSY.Storage},
        ::Type{<:AbstractNEMDispatch},
    )
    return Dict{Type{<:PSI.TimeSeriesParameter}, String}(
        RampUpRateTimeSeriesParameter => NEM_SERIES.ramp_up_rate,
        RampDownRateTimeSeriesParameter => NEM_SERIES.ramp_down_rate,
        InitialPowerTimeSeriesParameter => NEM_SERIES.initial_mw,
        PSI.ActivePowerOutTimeSeriesParameter => energy_max_avail_series_name(OfferSide.GEN),
        PSI.ActivePowerInTimeSeriesParameter => energy_max_avail_series_name(OfferSide.LOAD),
        _FIXED_LOAD_SERIES...,
    )
end


"""
    PSI.construct_device!(container, sys, ::PSI.ArgumentConstructStage, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_model) where {T <: PSY.Storage}

Argument stage for a battery under [`AbstractNEMDispatch`](@ref): the per-direction active
power variables, the ramp parameters, the raw availability
parameters, the initial conditions [`NEMLookaheadDispatch`](@ref)
requires, the incremental and decremental market-bid parameters, and the device's net
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
    PSI.add_variables!(container, EnergyMaxAvailOutSlack, devices, D())
    PSI.add_variables!(container, EnergyMaxAvailInSlack, devices, D())

    for param in _storage_parameters(D)
        haskey(PSI.get_time_series_names(model), param) || continue
        PSI.add_parameters!(container, param, devices, model)
    end

    _add_fixed_load_arguments!(container, devices, model)

    if PSI.requires_initialization(D())
        PSI.add_initial_condition!(container, devices, D(), PSI.DevicePower())
        PSI.add_initial_condition!(container, devices, D(), StorageInputDevicePower())
    end

    PSI.process_market_bid_parameters!(container, devices, model, true, true)
    for S in _ENERGY_OFFER_SLACK_TYPES
        PSI.add_variables!(container, S, devices, D())
    end
    PSI.add_cost_expressions!(container, devices, model)

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
envelope, the net ramp constraint and the market-bid objective.

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

    PSI.add_constraints!(container, EnergyMaxAvailOutConstraint, PSI.ActivePowerOutVariable, devices, model, network_model)
    PSI.add_constraints!(container, EnergyMaxAvailInConstraint, PSI.ActivePowerInVariable, devices, model, network_model)
    _add_storage_ramp_constraints!(container, devices, model)
    _add_fixed_load_constraints!(container, devices, T)

    PSI.add_feedforward_constraints!(container, model, devices)
    PSI.objective_function!(container, devices, model, PSI.get_network_formulation(network_model))
    PSI.add_constraint_dual!(container, sys, model)
    return
end


"""
    PSI.objective_function!(container, devices, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_formulation) where {T <: PSY.Storage}

Prices a battery's discharge on its incremental offer curve against
`PowerSimulations.ActivePowerOutVariable` and its charge on its decremental offer curve
against `PowerSimulations.ActivePowerInVariable`.

# Returns
`nothing`.
"""
function PSI.objective_function!(
        container::PSI.OptimizationContainer,
        devices::IS.FlattenIteratorWrapper{T},
        ::PSI.DeviceModel{T, D},
        ::Type{<:PM.AbstractPowerModel},
    ) where {T <: PSY.Storage, D <: AbstractNEMDispatch}
    PSI.add_variable_cost!(container, PSI.ActivePowerOutVariable(), devices, D())
    PSI.add_variable_cost!(container, PSI.ActivePowerInVariable(), devices, D())
    PSI.add_proportional_cost!(container, EnergyMaxAvailOutSlack(), devices, D())
    PSI.add_proportional_cost!(container, EnergyMaxAvailInSlack(), devices, D())
    _add_fixed_load_costs!(container, devices, T)
    for S in _ENERGY_OFFER_SLACK_TYPES
        PSI.add_proportional_cost!(container, S(), devices, D())
    end
    return
end


# Both formulations read live raw availability, independently of their ramp reference.
_storage_parameters(::Type{<:AbstractNEMDispatch}) = (
    RampUpRateTimeSeriesParameter, RampDownRateTimeSeriesParameter, InitialPowerTimeSeriesParameter,
    PSI.ActivePowerOutTimeSeriesParameter, PSI.ActivePowerInTimeSeriesParameter,
)


"""
    _add_storage_ramp_constraints!(container, devices, model)

Holds each battery's net `Out - In` within its per-interval ramp rates of the base its
formulation measures against, through [`_add_nem_ramp_constraints!`](@ref), so a net ramp
envelope that conflicts with the per-direction bounds is violated at the unit ramp CVP instead of
making the model infeasible.

# Returns
`nothing`.
"""
function _add_storage_ramp_constraints!(container, devices, model::PSI.DeviceModel{T, D}) where {T <: PSY.Storage, D <: AbstractNEMDispatch}
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


function _storage_ramp_base_accessor(container, ::Type{NEMLookaheadDispatch}, ::Type{T}, names, out, in_) where {T <: PSY.Storage}
    out_ic = Dict(
        PSI.get_component_name(ic) => PSI.get_value(ic)
            for ic in PSI.get_initial_condition(container, PSI.DevicePower(), T)
    )
    in_ic = Dict(
        PSI.get_component_name(ic) => PSI.get_value(ic)
            for ic in PSI.get_initial_condition(container, StorageInputDevicePower(), T)
    )
    _require_coverage(
        names, "no DevicePower initial condition", "The initial-conditions sub-model built none.",
        keys(out_ic), keys(in_ic),
    )
    return (name, t) -> t > 1 ? out[name, t - 1] - in_[name, t - 1] : out_ic[name] - in_ic[name]
end
