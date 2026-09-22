"""
    RampBase

Trait ancestor for the quantity a [`NEMDispatch`](@ref) ramp constraint measures against.
"""
abstract type RampBase end

"""
    MeteredRampBase

Ramp base taken from the device's `"initial_mw"` time series at every interval.
"""
struct MeteredRampBase <: RampBase end

"""
    ChainedRampBase

Ramp base taken from the `DevicePower` initial condition at the first interval and from the
previous interval's `ActivePowerVariable` thereafter.
"""
struct ChainedRampBase <: RampBase end

"""
    NEMDispatch{B <: RampBase}

Device formulation for a NEM dispatch participant: a per-band bid stack, a per-interval ramp
limit measured against `B`, and the `DISPATCHLOAD.AVAILABILITY` envelope.

NEMDE applies these to every scheduled resource identically, so the formulation is written
against `PowerSystems.StaticInjection` and is set per device type by the template, not
restricted to a fixed list of types. Technology enters through the numbers on the bid stack,
the rates and the envelope — never through the form of the constraints.

The formulation models a single injection variable per device. A device whose dispatch needs
more than that, such as a bidirectional unit tracking state of charge, layers that on as its
own formulation; NEMDE itself carries no state of charge.

`NEMDispatch` is a `UnionAll` as written and `PowerSimulations.jl` rejects it; use
[`NEMReplayDispatch`](@ref) or [`NEMLookaheadDispatch`](@ref).
"""
struct NEMDispatch{B <: RampBase} <: PSI.AbstractDeviceFormulation end

"""
    NEMReplayDispatch

[`NEMDispatch`](@ref) with a metered ramp base: every interval ramps from its own
`"initial_mw"`, as NEMDE does. Intervals are decoupled.
"""
const NEMReplayDispatch = NEMDispatch{MeteredRampBase}

"""
    NEMLookaheadDispatch

[`NEMDispatch`](@ref) with a chained ramp base: the first interval ramps from the `DevicePower`
initial condition and later intervals from the previous interval's dispatch.
"""
const NEMLookaheadDispatch = NEMDispatch{ChainedRampBase}

"""
    RampUpRateTimeSeriesParameter

Time-series parameter for a device's `"ramp_up_rate"` series, in system-base per-unit per minute.
"""
struct RampUpRateTimeSeriesParameter <: PSI.TimeSeriesParameter end

"""
    RampDownRateTimeSeriesParameter

Time-series parameter for a device's `"ramp_down_rate"` series, in system-base per-unit per minute.
"""
struct RampDownRateTimeSeriesParameter <: PSI.TimeSeriesParameter end

"""
    InitialPowerTimeSeriesParameter

Time-series parameter for a device's `"initial_mw"` series, in system-base per-unit.
"""
struct InitialPowerTimeSeriesParameter <: PSI.TimeSeriesParameter end

#! format: off
PSI.requires_initialization(::NEMDispatch{MeteredRampBase}) = false
PSI.requires_initialization(::NEMDispatch{ChainedRampBase}) = true

PSI.get_variable_binary(::PSI.ActivePowerVariable, ::Type{<:PSY.StaticInjection}, ::NEMDispatch) = false
PSI.get_variable_multiplier(::PSI.ActivePowerVariable, ::Type{<:PSY.StaticInjection}, ::NEMDispatch) = 1.0
PSI.get_variable_lower_bound(::PSI.ActivePowerVariable, ::PSY.StaticInjection, ::NEMDispatch) = 0.0
PSI.get_variable_upper_bound(::PSI.ActivePowerVariable, d::PSY.StaticInjection, ::NEMDispatch) = PSY.get_max_active_power(d)

# The "max_active_power" series is normalised by the device's static rating, so its parameter
# carries that rating as the multiplier. The three dispatch-limit series are stored as absolute
# system-base per-unit, so theirs is 1.0.
PSI.get_multiplier_value(::PSI.ActivePowerTimeSeriesParameter, d::PSY.StaticInjection, ::NEMDispatch) = PSY.get_max_active_power(d)
PSI.get_multiplier_value(::RampUpRateTimeSeriesParameter, ::PSY.StaticInjection, ::NEMDispatch) = 1.0
PSI.get_multiplier_value(::RampDownRateTimeSeriesParameter, ::PSY.StaticInjection, ::NEMDispatch) = 1.0
PSI.get_multiplier_value(::InitialPowerTimeSeriesParameter, ::PSY.StaticInjection, ::NEMDispatch) = 1.0
PSI.get_multiplier_value(::PSI.AbstractPiecewiseLinearBreakpointParameter, ::PSY.StaticInjection, ::NEMDispatch) = 1.0

PSI.get_min_max_limits(d::PSY.StaticInjection, ::Type{PSI.ActivePowerVariableLimitsConstraint}, ::Type{<:NEMDispatch}) = (min = 0.0, max = PSY.get_max_active_power(d))

PSI.objective_function_multiplier(::PSI.ActivePowerVariable, ::NEMDispatch) = PSI.OBJECTIVE_FUNCTION_POSITIVE
PSI.variable_cost(cost::PSY.OperationalCost, ::PSI.ActivePowerVariable, ::PSY.StaticInjection, ::NEMDispatch) = PSY.get_variable(cost)

PSI.initial_condition_default(::PSI.DevicePower, d::PSY.StaticInjection, ::NEMDispatch) = PSY.get_active_power(d)
PSI.initial_condition_variable(::PSI.DevicePower, ::PSY.StaticInjection, ::NEMDispatch) = PSI.ActivePowerVariable()
#! format: on

"""
    PSI.get_default_time_series_names(::Type{<:PSY.StaticInjection}, ::Type{<:NEMDispatch})

Registers the time series [`NEMDispatch`](@ref) reads as parameters. `"initial_mw"` is registered
only for [`NEMReplayDispatch`](@ref); the chained base reads a `DevicePower` initial condition
instead.

# Returns
A `Dict` mapping each `PowerSimulations.TimeSeriesParameter` type to its series name.
"""
function PSI.get_default_time_series_names(
        ::Type{<:PSY.StaticInjection},
        ::Type{NEMDispatch{MeteredRampBase}},
    )
    return Dict{Type{<:PSI.TimeSeriesParameter}, String}(
        PSI.ActivePowerTimeSeriesParameter => "max_active_power",
        RampUpRateTimeSeriesParameter => "ramp_up_rate",
        RampDownRateTimeSeriesParameter => "ramp_down_rate",
        InitialPowerTimeSeriesParameter => "initial_mw",
    )
end

function PSI.get_default_time_series_names(
        ::Type{<:PSY.StaticInjection},
        ::Type{NEMDispatch{ChainedRampBase}},
    )
    return Dict{Type{<:PSI.TimeSeriesParameter}, String}(
        PSI.ActivePowerTimeSeriesParameter => "max_active_power",
        RampUpRateTimeSeriesParameter => "ramp_up_rate",
        RampDownRateTimeSeriesParameter => "ramp_down_rate",
    )
end

"""
    PSI.get_default_attributes(::Type{<:PSY.StaticInjection}, ::Type{<:NEMDispatch})

[`NEMDispatch`](@ref) takes no device-model attributes.

# Returns
An empty `Dict{String, Any}`.
"""
function PSI.get_default_attributes(
        ::Type{<:PSY.StaticInjection},
        ::Type{<:NEMDispatch},
    )
    return Dict{String, Any}()
end

"""
    PSI.get_initial_conditions_device_model(::PSI.OperationModel, ::PSI.DeviceModel{T, <:NEMDispatch})

Device model used to build the initial-conditions sub-model that [`NEMLookaheadDispatch`](@ref)
requires.

# Returns
A `PowerSimulations.DeviceModel` over the same component type with [`NEMReplayDispatch`](@ref),
whose metered ramp base needs no initial condition of its own.
"""
function PSI.get_initial_conditions_device_model(
        ::PSI.OperationModel,
        ::PSI.DeviceModel{T, <:NEMDispatch},
    ) where {T <: PSY.StaticInjection}
    return PSI.DeviceModel(T, NEMReplayDispatch)
end

"""
    PSI.construct_device!(container, sys, ::PSI.ArgumentConstructStage, model::PSI.DeviceModel{T, <:NEMDispatch}, network_model)

Argument stage for [`NEMDispatch`](@ref): the active power variable, the availability envelope
and ramp parameters, the per-band bid variables, and the device's contribution to the active
power balance.

# Returns
`nothing`.
"""
function PSI.construct_device!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ArgumentConstructStage,
        model::PSI.DeviceModel{T, D},
        network_model::PSI.NetworkModel{<:PM.AbstractActivePowerModel},
    ) where {T <: PSY.StaticInjection, D <: NEMDispatch}
    devices = PSI.get_available_components(model, sys)

    PSI.add_variables!(container, PSI.ActivePowerVariable, devices, D())

    for param in (
            PSI.ActivePowerTimeSeriesParameter,
            RampUpRateTimeSeriesParameter,
            RampDownRateTimeSeriesParameter,
            InitialPowerTimeSeriesParameter,
        )
        haskey(PSI.get_time_series_names(model), param) || continue
        PSI.add_parameters!(container, param, devices, model)
    end

    PSI.process_market_bid_parameters!(container, devices, model)
    PSI.add_cost_expressions!(container, devices, model)

    PSI.add_to_expression!(
        container,
        PSI.ActivePowerBalance,
        PSI.ActivePowerVariable,
        devices,
        model,
        network_model,
    )

    # FCAS co-optimisation folds headroom into these, so they must exist whenever a service
    # model is attached.
    if PSI.has_service_model(model)
        PSI.add_to_expression!(
            container,
            PSI.ActivePowerRangeExpressionLB,
            PSI.ActivePowerVariable,
            devices,
            model,
            network_model,
        )
        PSI.add_to_expression!(
            container,
            PSI.ActivePowerRangeExpressionUB,
            PSI.ActivePowerVariable,
            devices,
            model,
            network_model,
        )
    end

    PSI.add_feedforward_arguments!(container, model, devices)
    return
end

"""
    PSI.construct_device!(container, sys, ::PSI.ModelConstructStage, model::PSI.DeviceModel{T, <:NEMDispatch}, network_model)

Model stage for [`NEMDispatch`](@ref): the availability envelope limits, the ramp constraint and
the market-bid objective.

# Returns
`nothing`.
"""
function PSI.construct_device!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ModelConstructStage,
        model::PSI.DeviceModel{T, D},
        network_model::PSI.NetworkModel{<:PM.AbstractActivePowerModel},
    ) where {T <: PSY.StaticInjection, D <: NEMDispatch}
    devices = PSI.get_available_components(model, sys)

    _check_dispatch_envelope(container, devices, model)

    if PSI.has_service_model(model)
        PSI.add_constraints!(
            container,
            PSI.ActivePowerVariableLimitsConstraint,
            PSI.ActivePowerRangeExpressionLB,
            devices,
            model,
            network_model,
        )
        PSI.add_constraints!(
            container,
            PSI.ActivePowerVariableLimitsConstraint,
            PSI.ActivePowerRangeExpressionUB,
            devices,
            model,
            network_model,
        )
    else
        PSI.add_constraints!(
            container,
            PSI.ActivePowerVariableLimitsConstraint,
            PSI.ActivePowerVariable,
            devices,
            model,
            network_model,
        )
    end

    PSI.add_constraints!(container, PSI.RampConstraint, PSI.ActivePowerVariable, devices, model, network_model)

    PSI.add_feedforward_constraints!(container, model, devices)
    PSI.objective_function!(container, devices, model, PSI.get_network_formulation(network_model))
    PSI.add_constraint_dual!(container, sys, model)
    return
end

"""
    PSI.add_constraints!(container, ::Type{PSI.ActivePowerVariableLimitsConstraint}, U, devices, model::PSI.DeviceModel{T, <:NEMDispatch}, network_model)

Bounds a [`NEMDispatch`](@ref) device's active power above by its
`PowerSimulations.ActivePowerTimeSeriesParameter`, which carries the `DISPATCHLOAD.AVAILABILITY`
envelope.

# Returns
`nothing`.
"""
function PSI.add_constraints!(
        container::PSI.OptimizationContainer,
        ::Type{PSI.ActivePowerVariableLimitsConstraint},
        U::Type{<:Union{PSI.VariableType, PSI.ActivePowerRangeExpressionUB}},
        devices::IS.FlattenIteratorWrapper{T},
        model::PSI.DeviceModel{T, D},
        ::PSI.NetworkModel{X},
    ) where {T <: PSY.StaticInjection, D <: NEMDispatch, X <: PM.AbstractPowerModel}
    PSI.add_parameterized_upper_bound_range_constraints(
        container,
        PSI.ActivePowerVariableTimeSeriesLimitsConstraint,
        U,
        PSI.ActivePowerTimeSeriesParameter,
        devices,
        model,
        X,
    )
    return
end

function PSI.add_constraints!(
        container::PSI.OptimizationContainer,
        T::Type{PSI.ActivePowerVariableLimitsConstraint},
        U::Type{PSI.ActivePowerRangeExpressionLB},
        devices::IS.FlattenIteratorWrapper{V},
        model::PSI.DeviceModel{V, D},
        ::PSI.NetworkModel{X},
    ) where {V <: PSY.StaticInjection, D <: NEMDispatch, X <: PM.AbstractPowerModel}
    PSI.add_range_constraints!(container, T, U, devices, model, X)
    return
end

"""
    PSI.add_constraints!(container, ::Type{PSI.RampConstraint}, ::Type{PSI.ActivePowerVariable}, devices, model::PSI.DeviceModel{T, NEMDispatch{B}}, network_model)

Holds each device's active power within its per-interval ramp rates of the base that `B`
selects. Rates are read from the `"ramp_up_rate"` and `"ramp_down_rate"` parameters as
system-base per-unit per minute and multiplied by the interval length in minutes.

# Returns
`nothing`.
"""
function PSI.add_constraints!(
        container::PSI.OptimizationContainer,
        ::Type{PSI.RampConstraint},
        ::Type{PSI.ActivePowerVariable},
        devices::IS.FlattenIteratorWrapper{T},
        model::PSI.DeviceModel{T, NEMDispatch{B}},
        ::PSI.NetworkModel{<:PM.AbstractPowerModel},
    ) where {T <: PSY.StaticInjection, B <: RampBase}
    time_steps = PSI.get_time_steps(container)
    jump_model = PSI.get_jump_model(container)
    minutes = PSI._get_minutes_per_period(container)
    power = PSI.get_variable(container, PSI.ActivePowerVariable(), T)

    names = [PSY.get_name(d) for d in devices]
    isempty(names) && return

    up_rate, up_covered = _ts_parameter_accessor(container, RampUpRateTimeSeriesParameter, T)
    down_rate, down_covered = _ts_parameter_accessor(container, RampDownRateTimeSeriesParameter, T)
    _require_rate_coverage(names, up_covered, down_covered)

    con_up = PSI.add_constraints_container!(
        container, PSI.RampConstraint(), T, names, time_steps; meta = "up",
    )
    con_dn = PSI.add_constraints_container!(
        container, PSI.RampConstraint(), T, names, time_steps; meta = "dn",
    )

    base_at = _ramp_base_accessor(container, B, T, power)
    for name in names, t in time_steps
        base = base_at(name, t)
        con_up[name, t] = JuMP.@constraint(
            jump_model, power[name, t] - base <= up_rate(name, t) * minutes,
        )
        con_dn[name, t] = JuMP.@constraint(
            jump_model, base - power[name, t] <= down_rate(name, t) * minutes,
        )
    end
    return
end

# A time-series parameter array is keyed by time-series UUID, not device name, so a value is
# read through `get_parameter_column_refs` and scaled by the name-keyed multiplier.
function _ts_parameter_accessor(container, ::Type{P}, ::Type{T}) where {P <: PSI.TimeSeriesParameter, T}
    param_container = PSI.get_parameter(container, P(), T)
    multiplier = PSI.get_multiplier_array(param_container)
    covered = Set(PSI.get_component_names(PSI.get_attributes(param_container)))
    function accessor(name, t)
        return PSI.get_parameter_column_refs(param_container, name)[t] * multiplier[name, t]
    end
    return accessor, covered
end

function _ramp_base_accessor(container, ::Type{MeteredRampBase}, ::Type{T}, _) where {T}
    initial, covered = _ts_parameter_accessor(container, InitialPowerTimeSeriesParameter, T)
    return (name, t) -> begin
        name in covered || throw(
            ArgumentError(
                "$name: NEMReplayDispatch needs an \"initial_mw\" time series and none is attached. " *
                    "Call set_nem_dispatch_limits! over the model's date range first.",
            ),
        )
        initial(name, t)
    end
end

function _ramp_base_accessor(container, ::Type{ChainedRampBase}, ::Type{T}, power) where {T}
    ic_power = Dict(
        PSI.get_component_name(ic) => PSI.get_value(ic)
            for ic in PSI.get_initial_condition(container, PSI.DevicePower(), T)
    )
    return (name, t) -> begin
        t > 1 && return power[name, t - 1]
        haskey(ic_power, name) || throw(
            ArgumentError(
                "$name: NEMLookaheadDispatch needs a DevicePower initial condition and none was built",
            ),
        )
        ic_power[name]
    end
end

# The root package's setters throw when DISPATCHLOAD has no usable rate, so a device missing one
# here means the setter was never run for it. Name those devices rather than let the parameter
# lookup fail on an internal key.
function _require_rate_coverage(names, up_covered, down_covered)
    missing_names = [n for n in names if !(n in up_covered) || !(n in down_covered)]
    isempty(missing_names) && return
    throw(
        ArgumentError(
            "NEMDispatch: no ramp rate time series for $(join(missing_names, ", ")). " *
                "Call set_nem_dispatch_limits! over the model's date range first.",
        ),
    )
end

"""
    PSI.objective_function!(container, devices, model::PSI.DeviceModel{T, <:NEMDispatch}, network_formulation)

Prices a [`NEMDispatch`](@ref) device's dispatch through `PowerSimulations.jl`'s market-bid
path, so the objective is the device's own submitted bid stack.

# Returns
`nothing`.
"""
function PSI.objective_function!(
        container::PSI.OptimizationContainer,
        devices::IS.FlattenIteratorWrapper{T},
        ::PSI.DeviceModel{T, D},
        ::Type{<:PM.AbstractPowerModel},
    ) where {T <: PSY.StaticInjection, D <: NEMDispatch}
    PSI.add_variable_cost!(container, PSI.ActivePowerVariable(), devices, D())
    return
end

"Per-unit slack allowed before a ramp-down floor above the availability ceiling is reported."
const ENVELOPE_TOLERANCE = 1.0e-6

# A ramp-down floor above the availability ceiling is infeasible. With rates, INITIALMW and
# AVAILABILITY all taken from the same DISPATCHLOAD row this cannot arise, so it signals
# inconsistent inputs: name the devices at build rather than return INFEASIBLE with no cause.
function _check_dispatch_envelope(container, devices, model)
    haskey(PSI.get_time_series_names(model), InitialPowerTimeSeriesParameter) || return
    isempty(devices) && return
    T = typeof(first(devices))
    time_steps = PSI.get_time_steps(container)
    minutes = PSI._get_minutes_per_period(container)
    initial, initial_covered = _ts_parameter_accessor(container, InitialPowerTimeSeriesParameter, T)
    down_rate, down_covered = _ts_parameter_accessor(container, RampDownRateTimeSeriesParameter, T)
    ceiling, ceiling_covered = _ts_parameter_accessor(container, PSI.ActivePowerTimeSeriesParameter, T)
    problems = String[]
    for d in devices
        name = PSY.get_name(d)
        all(name in c for c in (initial_covered, down_covered, ceiling_covered)) || continue
        for t in time_steps
            floor_mw = JuMP.value(initial(name, t)) - JuMP.value(down_rate(name, t)) * minutes
            ceiling_mw = JuMP.value(ceiling(name, t))
            if floor_mw > ceiling_mw + ENVELOPE_TOLERANCE
                push!(
                    problems,
                    "$name at interval $t: ramp-down floor $floor_mw exceeds availability $ceiling_mw",
                )
                break
            end
        end
    end
    isempty(problems) && return
    throw(
        ArgumentError(
            "NEMDispatch: inconsistent dispatch envelope for $(length(problems)) device(s):\n  " *
                join(problems, "\n  "),
        ),
    )
end

"""
    nem_dispatch_participants(sys)

The component types in `sys` that carry the per-interval dispatch limits
`set_nem_dispatch_limits!` attaches, and so participate in a NEMDE-style dispatch.

Membership is decided by the data on the components, not by a fixed list of types: any
`PowerSystems.StaticInjection` whose components carry a `"ramp_up_rate"` series qualifies.

# Arguments
- `sys`: the `PowerSystems.System` to inspect.

# Returns
A sorted `Vector` of component types.
"""
function nem_dispatch_participants(sys)
    types = Set{DataType}()
    for device in PSY.get_components(PSY.StaticInjection, sys)
        PSY.has_time_series(device, PSY.SingleTimeSeries, "ramp_up_rate") || continue
        push!(types, typeof(device))
    end
    return sort!(collect(types); by = string)
end

"""
    set_nem_dispatch_models!(template, sys; formulation = NEMReplayDispatch)

Sets `formulation` as the device model for every dispatch participant in `sys`, so all of them
are dispatched by the same rules.

# Arguments
- `template`: the `PowerSimulations.ProblemTemplate` to mutate.
- `sys`: the `PowerSystems.System` whose participants are read, via
  [`nem_dispatch_participants`](@ref).
- `formulation`: [`NEMReplayDispatch`](@ref) or [`NEMLookaheadDispatch`](@ref).

# Returns
The types the formulation was set for, as a `Vector`.
"""
function set_nem_dispatch_models!(template, sys; formulation = NEMReplayDispatch)
    types = nem_dispatch_participants(sys)
    isempty(types) && throw(
        ArgumentError(
            "no dispatch participants in this System: call set_nem_dispatch_limits! over the " *
                "model's date range first",
        ),
    )
    for T in types
        PSI.set_device_model!(template, T, formulation)
    end
    return types
end
