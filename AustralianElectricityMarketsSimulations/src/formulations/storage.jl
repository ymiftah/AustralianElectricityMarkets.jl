"Names of a battery's per-direction dispatch ceiling series, as [`set_storage_dispatch_ceilings!`](@ref) attaches them."
const _STORAGE_CEILING_SERIES = (gen = "storage_gen_ceiling", load = "storage_load_ceiling")

"Both energy offer `MAXAVAIL` series a battery needs for [`set_storage_dispatch_ceilings!`](@ref) to attach ceilings."
const _STORAGE_OFFER_SERIES = ("energy_max_avail", "energy_max_avail_decremental")

#! format: off
PSI.get_variable_binary(::PSI.ActivePowerOutVariable, ::Type{<:PSY.Storage}, ::AbstractNEMDispatch) = false

PSI.get_variable_binary(::PSI.ActivePowerInVariable, ::Type{<:PSY.Storage}, ::AbstractNEMDispatch) = false

PSI.get_variable_multiplier(::PSI.ActivePowerOutVariable, ::Type{<:PSY.Storage}, ::AbstractNEMDispatch) = 1.0

PSI.get_variable_multiplier(::PSI.ActivePowerInVariable, ::Type{<:PSY.Storage}, ::AbstractNEMDispatch) = -1.0

PSI.get_variable_lower_bound(::PSI.ActivePowerOutVariable, ::PSY.Storage, ::AbstractNEMDispatch) = 0.0

PSI.get_variable_lower_bound(::PSI.ActivePowerInVariable, ::PSY.Storage, ::AbstractNEMDispatch) = 0.0

PSI.get_variable_upper_bound(::PSI.ActivePowerOutVariable, d::PSY.Storage, ::NEMReplayDispatch) = _storage_ceiling_bound(d, _STORAGE_CEILING_SERIES.gen, PSY.get_output_active_power_limits(d).max)

PSI.get_variable_upper_bound(::PSI.ActivePowerInVariable, d::PSY.Storage, ::NEMReplayDispatch) = _storage_ceiling_bound(d, _STORAGE_CEILING_SERIES.load, PSY.get_input_active_power_limits(d).max)

PSI.get_variable_upper_bound(::PSI.ActivePowerOutVariable, d::PSY.Storage, ::NEMLookaheadDispatch) = PSY.get_output_active_power_limits(d).max

PSI.get_variable_upper_bound(::PSI.ActivePowerInVariable, d::PSY.Storage, ::NEMLookaheadDispatch) = PSY.get_input_active_power_limits(d).max

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
ramp and initial-power series, and the per-direction dispatch ceilings from
[`set_storage_dispatch_ceilings!`](@ref), which [`NEMReplayDispatch`](@ref) bounds the battery
by. Batteries register no `"max_active_power"` series.

# Returns
A `Dict` mapping each `PowerSimulations.TimeSeriesParameter` type to its series name.
"""
function PSI.get_default_time_series_names(
        ::Type{<:PSY.Storage},
        ::Type{<:AbstractNEMDispatch},
    )
    return Dict{Type{<:PSI.TimeSeriesParameter}, String}(
        RampUpRateTimeSeriesParameter => "ramp_up_rate",
        RampDownRateTimeSeriesParameter => "ramp_down_rate",
        InitialPowerTimeSeriesParameter => "initial_mw",
        PSI.ActivePowerOutTimeSeriesParameter => _STORAGE_CEILING_SERIES.gen,
        PSI.ActivePowerInTimeSeriesParameter => _STORAGE_CEILING_SERIES.load,
    )
end


"""
    PSI.construct_device!(container, sys, ::PSI.ArgumentConstructStage, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_model) where {T <: PSY.Storage}

Argument stage for a battery under [`AbstractNEMDispatch`](@ref): the per-direction active
power variables, the ramp parameters, for [`NEMReplayDispatch`](@ref) the dispatch-ceiling
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

    PSI.add_variables!(container, PSI.ActivePowerOutVariable, devices, D())
    PSI.add_variables!(container, PSI.ActivePowerInVariable, devices, D())

    D === NEMReplayDispatch && _check_storage_ceilings(container, devices, model)
    for param in _storage_parameters(D)
        haskey(PSI.get_time_series_names(model), param) || continue
        PSI.add_parameters!(container, param, devices, model)
    end

    if PSI.requires_initialization(D())
        PSI.add_initial_condition!(container, devices, D(), PSI.DevicePower())
        PSI.add_initial_condition!(container, devices, D(), StorageInputDevicePower())
    end

    PSI.process_market_bid_parameters!(container, devices, model, true, true)
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

Model stage for a battery under [`AbstractNEMDispatch`](@ref): the per-direction availability
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

    _add_storage_availability_constraints!(container, devices, model, network_model)
    _add_storage_ramp_constraints!(container, devices, model)

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
    return
end


# The time-series parameters a battery's argument stage adds under each formulation.
_storage_parameters(::Type{NEMLookaheadDispatch}) =
    (RampUpRateTimeSeriesParameter, RampDownRateTimeSeriesParameter, InitialPowerTimeSeriesParameter)
_storage_parameters(::Type{NEMReplayDispatch}) = (
    _storage_parameters(NEMLookaheadDispatch)..., PSI.ActivePowerOutTimeSeriesParameter, PSI.ActivePowerInTimeSeriesParameter,
)


# The maximum of `d`'s ceiling series `name` over its whole span, or `static` when `d` has none.
function _storage_ceiling_bound(d::PSY.Storage, name::String, static::Float64)
    PSY.has_time_series(d, PSY.SingleTimeSeries, name) || return static
    return maximum(PSY.get_time_series_values(PSY.SingleTimeSeries, d, name; ignore_scaling_factors = true))
end


"""
    _check_storage_ceilings(container, devices, model)

Throws `ArgumentError` naming every battery in `devices` that carries both energy offer
`"energy_max_avail"` and `"energy_max_avail_decremental"` series but no forecast of the model's
dispatch-ceiling series. A battery with only one direction has no ceilings and keeps its static bounds.

# Returns
`nothing`.
"""
function _check_storage_ceilings(
        container::PSI.OptimizationContainer, devices, model::PSI.DeviceModel{T, NEMReplayDispatch},
    ) where {T <: PSY.Storage}
    names = PSI.get_time_series_names(model)
    gen, load = names[PSI.ActivePowerOutTimeSeriesParameter], names[PSI.ActivePowerInTimeSeriesParameter]
    ts_type = PSI.get_default_time_series_type(container)
    uncovered = [
        PSY.get_name(d) for d in devices if all(name -> PSY.has_time_series(d, PSY.SingleTimeSeries, name), _STORAGE_OFFER_SERIES) &&
            !(PSY.has_time_series(d, ts_type, gen) && PSY.has_time_series(d, ts_type, load))
    ]
    isempty(uncovered) || throw(
        ArgumentError(
            "NEMReplayDispatch: $(length(uncovered)) battery(ies) carry an energy offer MAXAVAIL but no " *
                "\"$gen\"/\"$load\" forecast: $(join(uncovered, ", ")). Call set_storage_dispatch_ceilings!(sys) " *
                "before transform_single_time_series!.",
        ),
    )
    return
end


"""
    _add_storage_availability_constraints!(container, devices, model, network_model)

Bounds each battery's `PowerSimulations.ActivePowerOutVariable`/`ActivePowerInVariable` above by its
per-direction dispatch ceiling. Under [`NEMReplayDispatch`](@ref) the rows read the
`PowerSimulations.ActivePowerOutTimeSeriesParameter`/`ActivePowerInTimeSeriesParameter` of the
[`set_storage_dispatch_ceilings!`](@ref) series, and each variable's upper bound is the series'
maximum. Under [`NEMLookaheadDispatch`](@ref) the rows and per-interval variable bounds are the
energy offer `MAXAVAIL` ([`get_storage_energy_max_avail`](@ref)) over the model's window, read at
build. A battery with no such series keeps its static bounds and receives no rows.

# Returns
`nothing`.
"""
function _add_storage_availability_constraints!(
        container, devices, model::PSI.DeviceModel{T, NEMReplayDispatch}, network_model,
    ) where {T <: PSY.Storage}
    network = PSI.get_network_formulation(network_model)
    PSI.add_parameterized_upper_bound_range_constraints(
        container, PSI.ActivePowerOutVariableTimeSeriesLimitsConstraint, PSI.ActivePowerOutVariable,
        PSI.ActivePowerOutTimeSeriesParameter, devices, model, network,
    )
    PSI.add_parameterized_upper_bound_range_constraints(
        container, PSI.ActivePowerInVariableTimeSeriesLimitsConstraint, PSI.ActivePowerInVariable,
        PSI.ActivePowerInTimeSeriesParameter, devices, model, network,
    )
    return
end


function _add_storage_availability_constraints!(
        container, devices, model::PSI.DeviceModel{T, NEMLookaheadDispatch}, _,
    ) where {T <: PSY.Storage}
    isempty(devices) && return
    time_steps = PSI.get_time_steps(container)
    initial_time = PSI.get_initial_time(container)
    jump_model = PSI.get_jump_model(container)
    out = PSI.get_variable(container, PSI.ActivePowerOutVariable(), T)
    in_ = PSI.get_variable(container, PSI.ActivePowerInVariable(), T)
    avail = Dict{String, NamedTuple}()
    for d in devices
        a = get_storage_energy_max_avail(d, initial_time, length(time_steps))
        isnothing(a) || (avail[PSY.get_name(d)] = a)
    end
    names = collect(keys(avail))
    isempty(names) && return
    con_out = PSI.add_constraints_container!(
        container, PSI.ActivePowerVariableLimitsConstraint(), T, names, time_steps; meta = "out",
    )
    con_in = PSI.add_constraints_container!(
        container, PSI.ActivePowerVariableLimitsConstraint(), T, names, time_steps; meta = "in",
    )
    for name in names, t in time_steps
        gen, load = avail[name].gen[t], avail[name].load[t]
        isfinite(gen) && JuMP.set_upper_bound(out[name, t], gen)
        isfinite(load) && JuMP.set_upper_bound(in_[name, t], load)
        con_out[name, t] = JuMP.@constraint(jump_model, out[name, t] <= gen)
        con_in[name, t] = JuMP.@constraint(jump_model, in_[name, t] <= load)
    end
    return
end


"""
    _add_storage_ramp_constraints!(container, devices, model)

Holds each battery's net `Out - In` within its per-interval ramp rates of the base its
formulation measures against. Each row carries a [`UnitRampUpSlack`](@ref) or
[`UnitRampDownSlack`](@ref) priced at [`UNIT_RAMP_CVP_FACTOR`](@ref) times the Market Price Cap,
as for the generator ramp rows, so a net ramp envelope that conflicts with the per-direction
bounds is violated at that price instead of making the model infeasible.

# Returns
`nothing`.
"""
function _add_storage_ramp_constraints!(container, devices, model::PSI.DeviceModel{T, D}) where {T <: PSY.Storage, D <: AbstractNEMDispatch}
    time_steps = PSI.get_time_steps(container)
    jump_model = PSI.get_jump_model(container)
    minutes = PSI._get_minutes_per_period(container)
    out = PSI.get_variable(container, PSI.ActivePowerOutVariable(), T)
    in_ = PSI.get_variable(container, PSI.ActivePowerInVariable(), T)

    names = [PSY.get_name(d) for d in devices]
    isempty(names) && return

    up_rate, up_covered = _ts_parameter_accessor(container, RampUpRateTimeSeriesParameter, T)
    down_rate, down_covered = _ts_parameter_accessor(container, RampDownRateTimeSeriesParameter, T)
    _require_coverage(
        names, "no ramp rate time series", _SETTER_REMEDY, up_covered, down_covered,
    )

    con_up = PSI.add_constraints_container!(
        container, PSI.RampConstraint(), T, names, time_steps; meta = "up",
    )
    con_dn = PSI.add_constraints_container!(
        container, PSI.RampConstraint(), T, names, time_steps; meta = "down",
    )

    slack_up = _add_unit_ramp_slack!(container, UnitRampUpSlack, T, names, time_steps)
    slack_dn = _add_unit_ramp_slack!(container, UnitRampDownSlack, T, names, time_steps)

    base_at = _storage_ramp_base_accessor(container, D, T, names, out, in_)
    for name in names, t in time_steps
        base = base_at(name, t)
        net = out[name, t] - in_[name, t]
        con_up[name, t] = JuMP.@constraint(jump_model, net - base - slack_up[name, t] <= up_rate(name, t) * minutes)
        con_dn[name, t] = JuMP.@constraint(jump_model, base - net - slack_dn[name, t] <= down_rate(name, t) * minutes)
    end
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
