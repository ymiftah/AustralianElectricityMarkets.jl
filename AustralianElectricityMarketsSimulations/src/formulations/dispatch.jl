#! format: off
PSI.requires_initialization(::NEMReplayDispatch) = false

PSI.requires_initialization(::NEMLookaheadDispatch) = true


PSI.get_variable_binary(::PSI.ActivePowerVariable, ::Type{<:PSY.StaticInjection}, ::AbstractNEMDispatch) = false

PSI.get_variable_multiplier(::PSI.ActivePowerVariable, ::Type{<:PSY.StaticInjection}, ::AbstractNEMDispatch) = 1.0

# A scheduled load's ActivePowerVariable is its consumed MW (as DISPATCHLOAD and constraint terms
# report it); it enters the area balance as a withdrawal.
PSI.get_variable_multiplier(::PSI.ActivePowerVariable, ::Type{<:PSY.ControllableLoad}, ::AbstractNEMDispatch) = -1.0

PSI.get_variable_lower_bound(::PSI.ActivePowerVariable, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 0.0

PSI.get_variable_upper_bound(::PSI.ActivePowerVariable, ::PSY.StaticInjection, ::AbstractNEMDispatch) = nothing


# The dispatch-limit series are stored as absolute system-base per-unit.
PSI.get_multiplier_value(::RampUpRateTimeSeriesParameter, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 1.0

PSI.get_multiplier_value(::RampDownRateTimeSeriesParameter, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 1.0

PSI.get_multiplier_value(::InitialPowerTimeSeriesParameter, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 1.0

PSI.get_multiplier_value(::EnergyMaxAvailTimeSeriesParameter, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 1.0

PSI.get_multiplier_value(::EnergyUIGFTimeSeriesParameter, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 1.0

PSI.get_multiplier_value(::PSI.AbstractPiecewiseLinearBreakpointParameter, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 1.0


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
        RampUpRateTimeSeriesParameter => "ramp_up_rate",
        RampDownRateTimeSeriesParameter => "ramp_down_rate",
        InitialPowerTimeSeriesParameter => "initial_mw",
        EnergyMaxAvailTimeSeriesParameter => "energy_max_avail",
        EnergyUIGFTimeSeriesParameter => "energy_uigf",
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

Whether `device` carries every time series `formulation` reads as a parameter, including raw directional
availability for storage and UIGF only for semi-scheduled units.

# Arguments
- `device`: the `PowerSystems.Component` to inspect.
- `formulation`: an [`AbstractNEMDispatch`](@ref) subtype.

# Returns
`true` when every required registered series is attached, `false` otherwise.
"""
function _has_nem_dispatch_limits(device, formulation::Type{<:AbstractNEMDispatch})
    if !(device isa PSY.Storage)
        get(PSY.get_ext(device), "nem_semi_scheduled", nothing) isa Bool || return false
    end
    names = PSI.get_default_time_series_names(typeof(device), formulation)
    required = (
        name for (param, name) in names
            if param !== EnergyUIGFTimeSeriesParameter || PSY.get_ext(device)["nem_semi_scheduled"]
    )
    return all(
        PSY.has_time_series(device, PSY.SingleTimeSeries, name) for name in required
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


# Generators bid an incremental curve; a scheduled load bids only a decremental one.
_process_market_bid_parameters!(container, devices, model) =
    PSI.process_market_bid_parameters!(container, devices, model)

_process_market_bid_parameters!(container, devices::IS.FlattenIteratorWrapper{<:PSY.ControllableLoad}, model) =
    PSI.process_market_bid_parameters!(container, devices, model, false, true)


"""
    PSI.construct_device!(container, sys, ::PSI.ArgumentConstructStage, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_model)

Argument stage for [`AbstractNEMDispatch`](@ref): the active power variable, the separate energy
limit and ramp parameters, the per-band bid variables, and the device's contribution to the
active power balance.

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

    _check_energy_limit_series(sys, model, PSI.get_initial_time(container), length(PSI.get_time_steps(container)))

    PSI.add_variables!(container, PSI.ActivePowerVariable, devices, D())
    # A non-scheduled load has no energy offer and is never dispatched for energy (it only offers
    # FCAS), so its energy is held at 0 MW rather than left to the elastic MaxAvail row.
    for d in devices
        AustralianElectricityMarkets._is_non_scheduled_load(d) || continue
        for t in PSI.get_time_steps(container)
            JuMP.fix(PSI.get_variable(container, PSI.ActivePowerVariable(), T)[PSY.get_name(d), t], 0.0; force = true)
        end
    end
    PSI.add_variables!(container, EnergyMaxAvailSlack, devices, D())
    semi = _semi_scheduled_devices(devices)
    isempty(semi) || PSI.add_variables!(container, EnergyUIGFSlack, semi, D())

    for param in (
            RampUpRateTimeSeriesParameter,
            RampDownRateTimeSeriesParameter,
            InitialPowerTimeSeriesParameter,
            EnergyMaxAvailTimeSeriesParameter,
        )
        haskey(PSI.get_time_series_names(model), param) || continue
        PSI.add_parameters!(container, param, devices, model)
    end
    any(d -> PSY.get_ext(d)["nem_semi_scheduled"], devices) &&
        PSI.add_parameters!(container, EnergyUIGFTimeSeriesParameter, devices, model)

    # The chained base measures interval 1 against a DevicePower initial condition, which has to
    # be declared here for PowerSimulations to populate it from the initialisation sub-solve.
    PSI.requires_initialization(D()) &&
        PSI.add_initial_condition!(container, devices, D(), PSI.DevicePower())

    _process_market_bid_parameters!(container, devices, model)
    PSI.add_cost_expressions!(container, devices, model)

    PSI.add_to_expression!(
        container,
        PSI.ActivePowerBalance,
        PSI.ActivePowerVariable,
        devices,
        model,
        network_model,
    )

    PSI.add_feedforward_arguments!(container, model, devices)
    return
end


"""
    PSI.construct_device!(container, sys, ::PSI.ModelConstructStage, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_model)

Model stage for [`AbstractNEMDispatch`](@ref): the elastic energy availability constraints, the ramp
constraint and the market-bid objective.

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

    PSI.add_constraints!(container, EnergyMaxAvailConstraint, PSI.ActivePowerVariable, devices, model, network_model)
    PSI.add_constraints!(container, EnergyUIGFConstraint, PSI.ActivePowerVariable, _semi_scheduled_devices(devices), model, network_model)

    PSI.add_constraints!(container, PSI.RampConstraint, PSI.ActivePowerVariable, devices, model, network_model)

    PSI.add_feedforward_constraints!(container, model, devices)
    PSI.objective_function!(container, devices, model, PSI.get_network_formulation(network_model))
    PSI.add_constraint_dual!(container, sys, model)
    return
end


"""
    PSI.add_constraints!(container, ::Type{PSI.RampConstraint}, ::Type{PSI.ActivePowerVariable}, devices, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_model)

Holds each device's active power within its per-interval ramp rates of the base its formulation
measures against. Rates are read from the `"ramp_up_rate"` and `"ramp_down_rate"` parameters in
system-base per-unit per minute and multiplied by the interval length in minutes. Each row carries
a [`UnitRampUpSlack`](@ref) or [`UnitRampDownSlack`](@ref) priced at [`UNIT_RAMP_CVP_FACTOR`](@ref)
times the Market Price Cap. Conflicts with energy availability and UIGF are resolved through
the competing violation costs.

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

    slack_up = _add_unit_ramp_slack!(container, UnitRampUpSlack, T, names, time_steps)
    slack_dn = _add_unit_ramp_slack!(container, UnitRampDownSlack, T, names, time_steps)

    base_at = _ramp_base_accessor(container, D, T, names, power)
    for name in names, t in time_steps
        base = base_at(name, t)
        con_up[name, t] = JuMP.@constraint(
            jump_model, power[name, t] - base - slack_up[name, t] <= up_rate(name, t) * minutes,
        )
        con_dn[name, t] = JuMP.@constraint(
            jump_model, base - power[name, t] - slack_dn[name, t] <= down_rate(name, t) * minutes,
        )
    end
    return
end


"""
    _add_unit_ramp_slack!(container, var_type, T, names, time_steps)

Builds a non-negative slack variable of `var_type` per `(name, t)` and prices it in the objective
at [`UNIT_RAMP_CVP_FACTOR`](@ref) times the Market Price Cap ([`_container_market_price_cap`](@ref))
for the interval, in `\$/MW` per dispatch interval. The variable is in system-base per-unit, like
the ramp row it relaxes.

# Arguments
- `container`: the `PSI.OptimizationContainer` being built.
- `var_type`: [`UnitRampUpSlack`](@ref) or [`UnitRampDownSlack`](@ref).
- `T`: the component type owning the ramp rows.
- `names`, `time_steps`: the device names and time steps of the rows.

# Returns
The slack variable container.
"""
function _add_unit_ramp_slack!(container::PSI.OptimizationContainer, var_type, ::Type{T}, names, time_steps) where {T}
    return _add_cvp_slack!(container, var_type, T, names, time_steps, UNIT_RAMP_CVP_FACTOR)
end


"""
    _add_cvp_slack!(container, var_type, T, names, time_steps, cvp_factor)

Builds a non-negative slack variable of `var_type` per `(name, t)` and prices it in the objective
at `cvp_factor` times the Market Price Cap ([`_container_market_price_cap`](@ref)) for the
interval, in `\$/MW` per dispatch interval. The variable is in system-base per-unit.

# Arguments
- `container`: the `PSI.OptimizationContainer` being built.
- `var_type`: the slack `PSI.VariableType`.
- `T`: the component type owning the relaxed rows.
- `names`, `time_steps`: the device names and time steps of the rows.
- `cvp_factor`: the AEMO CVP factor the slack is priced at, times the Market Price Cap.

# Returns
The slack variable container.
"""
function _add_cvp_slack!(container::PSI.OptimizationContainer, var_type, ::Type{T}, names, time_steps, cvp_factor::Real) where {T}
    jm = PSI.get_jump_model(container)
    resolution = PSI.get_resolution(container)
    initial_time = PSI.get_initial_time(container)
    base_power = PSI.get_base_power(container)
    slack = PSI.add_variable_container!(container, var_type(), T, names, time_steps)
    for t in time_steps
        mpc = _container_market_price_cap(container, initial_time + resolution * (t - 1))
        coefficient = base_power * interval_cost_coefficient(cvp_factor * mpc, resolution)
        for name in names
            slack[name, t] = JuMP.@variable(jm, base_name = "$(nameof(var_type))_{$name,$t}", lower_bound = 0.0)
            PSI.add_to_objective_invariant_expression!(container, slack[name, t] * coefficient)
        end
    end
    return slack
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
    PSI.add_proportional_cost!(container, EnergyMaxAvailSlack(), devices, D())
    PSI.add_proportional_cost!(container, EnergyUIGFSlack(), _semi_scheduled_devices(devices), D())
    return
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
    set_nem_dispatch_models!(template, sys; formulation = NEMReplayDispatch, skip_uncovered = false, tie_breaks = true)

Sets `formulation` as the device model for every dispatch participant in `sys`, and, when `sys`
carries the [`EnergyTieBreak`](@ref) of [`set_tie_break_scales!`](@ref), its [`TieBreakMarket`](@ref)
service model, which dispatches price-tied energy bands pro rata. Without it ties resolve to an
arbitrary solver vertex.

# Arguments
- `template`: the `PowerSimulations.ProblemTemplate` to mutate.
- `sys`: the `PowerSystems.System` whose participants are read, via
  [`nem_dispatch_participants`](@ref).
- `formulation`: [`NEMReplayDispatch`](@ref) or [`NEMLookaheadDispatch`](@ref).
- `skip_uncovered`: when `true`, each device model carries a `"filter_function"` attribute
  excluding components that fail [`_has_nem_dispatch_limits`](@ref), and the excluded names are
  warned about. When `false` such a component fails the build by name.
- `tie_breaks`: when `false`, no tie-break service model is set.

# Returns
The types the formulation was set for, as a `Vector`.
"""
function set_nem_dispatch_models!(
        template, sys; formulation = NEMReplayDispatch, skip_uncovered::Bool = false, tie_breaks::Bool = true,
    )
    types = nem_dispatch_participants(sys, formulation)
    isempty(types) && throw(
        ArgumentError(
            "no dispatch participants in this System: call set_market_bids!, set_nem_dispatch_limits! and set_nem_energy_limits! over the " *
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
    else
        foreach(T -> PSI.set_device_model!(template, T, formulation), types)
    end
    if tie_breaks && !isnothing(PSY.get_component(EnergyTieBreak, sys, TIE_BREAK_SERVICE_NAME))
        PSI.set_service_model!(
            template, TIE_BREAK_SERVICE_NAME, PSI.ServiceModel(EnergyTieBreak, TieBreakMarket, TIE_BREAK_SERVICE_NAME),
        )
    end
    return types
end
