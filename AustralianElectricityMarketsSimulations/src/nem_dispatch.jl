"""
    AbstractNEMDispatch

Supertype for the NEM dispatch device formulations: a per-band bid stack, a per-interval ramp
limit, and the `DISPATCHLOAD.AVAILABILITY` envelope, applied to one active power variable per
device.

Methods are defined over `PowerSystems.StaticInjection`; a `PowerSimulations.ProblemTemplate`
selects the component types they apply to. Subtypes differ only in what the ramp constraint
measures against: [`NEMReplayDispatch`](@ref) and [`NEMLookaheadDispatch`](@ref).
"""
abstract type AbstractNEMDispatch <: PSI.AbstractDeviceFormulation end

"""
    NEMReplayDispatch

[`AbstractNEMDispatch`](@ref) whose ramp constraint measures against the device's `"initial_mw"`
time series at every interval. Intervals are decoupled.
"""
struct NEMReplayDispatch <: AbstractNEMDispatch end

"""
    NEMLookaheadDispatch

[`AbstractNEMDispatch`](@ref) whose ramp constraint measures against the `DevicePower` initial
condition at the first interval and the previous interval's `ActivePowerVariable` thereafter.
"""
struct NEMLookaheadDispatch <: AbstractNEMDispatch end

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
PSI.requires_initialization(::NEMReplayDispatch) = false
PSI.requires_initialization(::NEMLookaheadDispatch) = true

PSI.get_variable_binary(::PSI.ActivePowerVariable, ::Type{<:PSY.StaticInjection}, ::AbstractNEMDispatch) = false
PSI.get_variable_multiplier(::PSI.ActivePowerVariable, ::Type{<:PSY.StaticInjection}, ::AbstractNEMDispatch) = 1.0
PSI.get_variable_lower_bound(::PSI.ActivePowerVariable, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 0.0
PSI.get_variable_upper_bound(::PSI.ActivePowerVariable, d::PSY.StaticInjection, ::AbstractNEMDispatch) = PSY.get_max_active_power(d)

# "max_active_power" is stored normalised by the static rating; the dispatch-limit series are
# stored as absolute system-base per-unit.
PSI.get_multiplier_value(::PSI.ActivePowerTimeSeriesParameter, d::PSY.StaticInjection, ::AbstractNEMDispatch) = PSY.get_max_active_power(d)
PSI.get_multiplier_value(::RampUpRateTimeSeriesParameter, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 1.0
PSI.get_multiplier_value(::RampDownRateTimeSeriesParameter, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 1.0
PSI.get_multiplier_value(::InitialPowerTimeSeriesParameter, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 1.0
PSI.get_multiplier_value(::PSI.AbstractPiecewiseLinearBreakpointParameter, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 1.0

PSI.get_min_max_limits(d::PSY.StaticInjection, ::Type{PSI.ActivePowerVariableLimitsConstraint}, ::Type{<:AbstractNEMDispatch}) = (min = 0.0, max = PSY.get_max_active_power(d))

PSI.objective_function_multiplier(::PSI.ActivePowerVariable, ::AbstractNEMDispatch) = PSI.OBJECTIVE_FUNCTION_POSITIVE
PSI.variable_cost(cost::PSY.OperationalCost, ::PSI.ActivePowerVariable, ::PSY.StaticInjection, ::AbstractNEMDispatch) = PSY.get_variable(cost)

PSI.initial_condition_default(::PSI.DevicePower, d::PSY.StaticInjection, ::AbstractNEMDispatch) = PSY.get_active_power(d)
PSI.initial_condition_variable(::PSI.DevicePower, ::PSY.StaticInjection, ::AbstractNEMDispatch) = PSI.ActivePowerVariable()
#! format: on

"""
    PSI.get_default_time_series_names(::Type{<:PSY.StaticInjection}, ::Type{<:AbstractNEMDispatch})

Registers the time series [`AbstractNEMDispatch`](@ref) reads as parameters. Both modes register
`"initial_mw"`: `PowerSimulations.jl` copies the parent model's names onto the
initial-conditions sub-model, which runs [`NEMReplayDispatch`](@ref) and reads it.

# Returns
A `Dict` mapping each `PowerSimulations.TimeSeriesParameter` type to its series name.
"""
function PSI.get_default_time_series_names(
        ::Type{<:PSY.StaticInjection},
        ::Type{<:AbstractNEMDispatch},
    )
    return Dict{Type{<:PSI.TimeSeriesParameter}, String}(
        PSI.ActivePowerTimeSeriesParameter => "max_active_power",
        RampUpRateTimeSeriesParameter => "ramp_up_rate",
        RampDownRateTimeSeriesParameter => "ramp_down_rate",
        InitialPowerTimeSeriesParameter => "initial_mw",
    )
end

"""
    PSI.get_default_attributes(::Type{<:PSY.StaticInjection}, ::Type{<:AbstractNEMDispatch})

[`AbstractNEMDispatch`](@ref) takes no device-model attributes by default.

# Returns
An empty `Dict{String, Any}`.
"""
function PSI.get_default_attributes(
        ::Type{<:PSY.StaticInjection},
        ::Type{<:AbstractNEMDispatch},
    )
    return Dict{String, Any}()
end

"""
    _has_nem_dispatch_limits(device, formulation)

Whether `device` carries every time series `formulation` reads as a parameter.

# Arguments
- `device`: the `PowerSystems.Component` to inspect.
- `formulation`: an [`AbstractNEMDispatch`](@ref) subtype.

# Returns
`true` when every registered series is attached, `false` otherwise.
"""
function _has_nem_dispatch_limits(device, formulation::Type{<:AbstractNEMDispatch})
    names = PSI.get_default_time_series_names(typeof(device), formulation)
    return all(
        PSY.has_time_series(device, PSY.SingleTimeSeries, name) for name in values(names)
    )
end

"""
    PSI.get_initial_conditions_device_model(::PSI.OperationModel, ::PSI.DeviceModel{T, <:AbstractNEMDispatch})

Device model used to build the initial-conditions sub-model that [`NEMLookaheadDispatch`](@ref)
requires.

# Returns
A `PowerSimulations.DeviceModel` over the same component type with [`NEMReplayDispatch`](@ref).
"""
function PSI.get_initial_conditions_device_model(
        ::PSI.OperationModel,
        ::PSI.DeviceModel{T, <:AbstractNEMDispatch},
    ) where {T <: PSY.StaticInjection}
    return PSI.DeviceModel(T, NEMReplayDispatch)
end

"""
    PSI.construct_device!(container, sys, ::PSI.ArgumentConstructStage, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_model)

Argument stage for [`AbstractNEMDispatch`](@ref): the active power variable, the availability envelope
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
    ) where {T <: PSY.StaticInjection, D <: AbstractNEMDispatch}
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

    # The chained base measures interval 1 against a DevicePower initial condition, which has to
    # be declared here for PowerSimulations to populate it from the initialisation sub-solve.
    PSI.requires_initialization(D()) &&
        PSI.add_initial_condition!(container, devices, D(), PSI.DevicePower())

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

    # A service model folds its headroom into these range expressions.
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
    PSI.construct_device!(container, sys, ::PSI.ModelConstructStage, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_model)

Model stage for [`AbstractNEMDispatch`](@ref): the availability envelope limits, the ramp constraint and
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
    ) where {T <: PSY.StaticInjection, D <: AbstractNEMDispatch}
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
    PSI.add_constraints!(container, ::Type{PSI.ActivePowerVariableLimitsConstraint}, U, devices, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_model)

Bounds an [`AbstractNEMDispatch`](@ref) device's active power above by its
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
    ) where {T <: PSY.StaticInjection, D <: AbstractNEMDispatch, X <: PM.AbstractPowerModel}
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
    ) where {V <: PSY.StaticInjection, D <: AbstractNEMDispatch, X <: PM.AbstractPowerModel}
    PSI.add_range_constraints!(container, T, U, devices, model, X)
    return
end

"""
    PSI.add_constraints!(container, ::Type{PSI.RampConstraint}, ::Type{PSI.ActivePowerVariable}, devices, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_model)

Holds each device's active power within its per-interval ramp rates of the base its formulation
measures against. Rates are read from the `"ramp_up_rate"` and `"ramp_down_rate"` parameters in
system-base per-unit per minute and multiplied by the interval length in minutes.

# Returns
`nothing`.
"""
function PSI.add_constraints!(
        container::PSI.OptimizationContainer,
        ::Type{PSI.RampConstraint},
        ::Type{PSI.ActivePowerVariable},
        devices::IS.FlattenIteratorWrapper{T},
        model::PSI.DeviceModel{T, D},
        ::PSI.NetworkModel{<:PM.AbstractPowerModel},
    ) where {T <: PSY.StaticInjection, D <: AbstractNEMDispatch}
    time_steps = PSI.get_time_steps(container)
    jump_model = PSI.get_jump_model(container)
    minutes = PSI._get_minutes_per_period(container)
    power = PSI.get_variable(container, PSI.ActivePowerVariable(), T)

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

    base_at = _ramp_base_accessor(container, D, T, names, power)
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

# Parameter arrays are keyed by time-series UUID, not device name.
function _ts_parameter_accessor(container, ::Type{P}, ::Type{T}) where {P <: PSI.TimeSeriesParameter, T}
    param_container = PSI.get_parameter(container, P(), T)
    multiplier = PSI.get_multiplier_array(param_container)
    covered = Set(PSI.get_component_names(PSI.get_attributes(param_container)))
    function accessor(name, t)
        return PSI.get_parameter_column_refs(param_container, name)[t] * multiplier[name, t]
    end
    return accessor, covered
end

function _ramp_base_accessor(container, ::Type{NEMReplayDispatch}, ::Type{T}, names, _) where {T}
    PSI.has_container_key(container, InitialPowerTimeSeriesParameter, T) || throw(
        ArgumentError(
            "NEMReplayDispatch: the device model registers no \"initial_mw\" parameter, so the " *
                "ramp has no base to measure against",
        ),
    )
    initial, covered = _ts_parameter_accessor(container, InitialPowerTimeSeriesParameter, T)
    _require_coverage(names, "no \"initial_mw\" time series", _SETTER_REMEDY, covered)
    return initial
end

function _ramp_base_accessor(container, ::Type{NEMLookaheadDispatch}, ::Type{T}, names, power) where {T}
    ic_power = Dict(
        PSI.get_component_name(ic) => PSI.get_value(ic)
            for ic in PSI.get_initial_condition(container, PSI.DevicePower(), T)
    )
    _require_coverage(
        names, "no DevicePower initial condition", "The initial-conditions sub-model built none.",
        keys(ic_power),
    )
    return (name, t) -> t > 1 ? power[name, t - 1] : ic_power[name]
end

const _SETTER_REMEDY = "Call set_nem_dispatch_limits! over the model's date range first."

# Names every uncovered device up front, before the constraint loop reaches an internal key.
function _require_coverage(names, problem, remedy, covered...)
    missing_names = [n for n in names if any(!in(n, c) for c in covered)]
    isempty(missing_names) && return
    throw(
        ArgumentError(
            "NEMDispatch: $problem for $(join(missing_names, ", ")). $remedy",
        ),
    )
end

"""
    PSI.objective_function!(container, devices, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_formulation)

Prices an [`AbstractNEMDispatch`](@ref) device's dispatch through `PowerSimulations.jl`'s
market-bid path, so the objective is the device's own submitted bid stack.

# Returns
`nothing`.
"""
function PSI.objective_function!(
        container::PSI.OptimizationContainer,
        devices::IS.FlattenIteratorWrapper{T},
        ::PSI.DeviceModel{T, D},
        ::Type{<:PM.AbstractPowerModel},
    ) where {T <: PSY.StaticInjection, D <: AbstractNEMDispatch}
    PSI.add_variable_cost!(container, PSI.ActivePowerVariable(), devices, D())
    return
end

"Per-unit slack allowed before a ramp-down floor above the availability ceiling is reported."
const _RAMP_FLOOR_TOLERANCE = 1.0e-6

# A ramp-down floor above the availability ceiling is infeasible; report it at build.
function _check_dispatch_envelope(container, devices, model)
    # Only the replay mode has a metered floor; the lookahead floor is a variable. The name check
    # is not redundant: the initial-conditions sub-model pairs this formulation with the parent
    # model's registered names.
    PSI.get_formulation(model) === NEMReplayDispatch || return
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
            if floor_mw > ceiling_mw + _RAMP_FLOOR_TOLERANCE
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

The component types in `sys` that participate in a NEM dispatch: any
`PowerSystems.StaticInjection` with at least one component satisfying
[`_has_nem_dispatch_limits`](@ref) for `formulation`.

# Arguments
- `sys`: the `PowerSystems.System` to inspect.
- `formulation`: the [`AbstractNEMDispatch`](@ref) subtype whose series set decides membership.

# Returns
A sorted `Vector` of component types.
"""
function nem_dispatch_participants(sys, formulation::Type{<:AbstractNEMDispatch} = NEMReplayDispatch)
    types = Set{DataType}()
    for device in PSY.get_components(PSY.StaticInjection, sys)
        _has_nem_dispatch_limits(device, formulation) || continue
        push!(types, typeof(device))
    end
    return sort!(collect(types); by = string)
end

function _uncovered_names(sys, types, formulation)
    names = String[]
    for T in types, device in PSY.get_components(T, sys)
        PSY.get_available(device) || continue
        _has_nem_dispatch_limits(device, formulation) && continue
        push!(names, PSY.get_name(device))
    end
    return names
end

"""
    set_nem_dispatch_models!(template, sys; formulation = NEMReplayDispatch)

Sets `formulation` as the device model for every dispatch participant in `sys`.

# Arguments
- `template`: the `PowerSimulations.ProblemTemplate` to mutate.
- `sys`: the `PowerSystems.System` whose participants are read, via
  [`nem_dispatch_participants`](@ref).
- `formulation`: [`NEMReplayDispatch`](@ref) or [`NEMLookaheadDispatch`](@ref).
- `skip_uncovered`: when `true`, each device model carries a `"filter_function"` attribute
  excluding components that fail [`_has_nem_dispatch_limits`](@ref), and the excluded names are
  warned about. When `false` such a component fails the build by name.

# Returns
The types the formulation was set for, as a `Vector`.
"""
function set_nem_dispatch_models!(
        template, sys; formulation = NEMReplayDispatch, skip_uncovered::Bool = false,
    )
    types = nem_dispatch_participants(sys, formulation)
    isempty(types) && throw(
        ArgumentError(
            "no dispatch participants in this System: call set_nem_dispatch_limits! over the " *
                "model's date range first",
        ),
    )
    if skip_uncovered
        uncovered = _uncovered_names(sys, types, formulation)
        isempty(uncovered) || @warn "set_nem_dispatch_models!: excluding " *
            "$(length(uncovered)) component(s) with no $formulation time series: " *
            "$(join(uncovered, ", "))"
        for T in types
            PSI.set_device_model!(
                template,
                PSI.DeviceModel(
                    T, formulation;
                    attributes = Dict{String, Any}(
                        "filter_function" => d -> _has_nem_dispatch_limits(d, formulation),
                    ),
                ),
            )
        end
        return types
    end
    for T in types
        PSI.set_device_model!(template, T, formulation)
    end
    return types
end
