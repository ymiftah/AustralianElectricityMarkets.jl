#! format: off
PSI.requires_initialization(::NEMReplayDispatch) = false


PSI.get_variable_binary(::PSI.ActivePowerVariable, ::Type{<:PSY.StaticInjection}, ::AbstractNEMDispatch) = false

PSI.get_variable_multiplier(::PSI.ActivePowerVariable, ::Type{<:PSY.StaticInjection}, ::AbstractNEMDispatch) = 1.0

# A scheduled load's ActivePowerVariable is its consumed MW (as DISPATCHLOAD and constraint terms
# report it); it enters the area balance as a withdrawal.
PSI.get_variable_multiplier(::PSI.ActivePowerVariable, ::Type{<:PSY.ControllableLoad}, ::AbstractNEMDispatch) = -1.0

PSI.get_variable_lower_bound(::PSI.ActivePowerVariable, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 0.0

PSI.get_variable_upper_bound(::PSI.ActivePowerVariable, ::PSY.StaticInjection, ::AbstractNEMDispatch) = nothing


# The dispatch-limit series are stored as absolute system-base per-unit.
PSI.get_multiplier_value(::RampRateTimeSeriesParameter, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 1.0

PSI.get_multiplier_value(::InitialPowerTimeSeriesParameter, d::PSY.StaticInjection, ::AbstractNEMDispatch) = 1 / PSY.get_system_base_power(d)

PSI.get_multiplier_value(::EnergyMaxAvailTimeSeriesParameter, d::PSY.StaticInjection, ::AbstractNEMDispatch) = 1 / PSY.get_system_base_power(d)

PSI.get_multiplier_value(::EnergyUIGFTimeSeriesParameter, d::PSY.StaticInjection, ::AbstractNEMDispatch) = 1 / PSY.get_system_base_power(d)


PSI.objective_function_multiplier(::PSI.ActivePowerVariable, ::AbstractNEMDispatch) = PSI.OBJECTIVE_FUNCTION_POSITIVE

#! format: on

"""
    PSI.get_default_time_series_names(::Type{<:PSY.StaticInjection}, ::Type{<:AbstractNEMDispatch})

Registers the time series [`AbstractNEMDispatch`](@ref) reads as parameters. The derived series are
read through the device's [`NEMDispatchInputs`](@ref), and the telemetered UIGF keeps a name
constant. [`RampRateTimeSeriesParameter`](@ref) is registered once: its two directions are added with
their own series names. The initial-power and fixed-loading parameters are added explicitly from the build's
first-solve seed series, so they take no entry here.

# Returns
A `Dict` mapping each `PowerSimulations.TimeSeriesParameter` type to its series name.
"""
function PSI.get_default_time_series_names(
        ::Type{<:PSY.StaticInjection},
        ::Type{<:AbstractNEMDispatch},
    )
    return Dict{Type{<:PSI.TimeSeriesParameter}, String}(
        RampRateTimeSeriesParameter => NEM_SERIES.ramp_up_rate,
        EnergyMaxAvailTimeSeriesParameter => _max_avail_series_name(OfferSide.GEN),
        EnergyUIGFTimeSeriesParameter => NEM_TELEMETRY_SERIES.uigf,
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
    _has_nem_dispatch_limits(device)

Whether `device` carries every derived input [`NEMReplayDispatch`](@ref) reads as a parameter, as a
[`NEMDispatchInputs`](@ref) attribute, and the observed state and telemetry series it reads through.
The observed state's keyed series and the UIGF's series must exist. The ramp series must be the names
the parameters register; the energy availability keys name their own series, which the device's bid
or zero series determines, so they are checked by key.

# Arguments
- `device`: the `PowerSystems.Component` to inspect.

# Returns
`true` when every required registered series is attached, `false` otherwise.
"""
function _has_nem_dispatch_limits(device)
    if !(device isa PSY.Storage)
        has_registration(device) || return false
    end
    observed = _unit_observed(device)
    telemetry = _unit_telemetry(device)
    (isnothing(observed) || isnothing(telemetry)) && return false
    observed.initial_mw isa IS.StaticTimeSeriesKey || return false
    PSY.has_time_series(
        device,
        PSY.SingleTimeSeries,
        PSY.get_name(observed.initial_mw),
    ) || return false
    attributes = PSY.get_supplemental_attributes(NEMDispatchInputs, device)::Vector{NEMDispatchInputs}
    length(attributes) == 1 || return false
    inputs = only(attributes)
    names = PSI.get_default_time_series_names(typeof(device), NEMReplayDispatch)
    for (param, direction, field) in _DERIVED_INPUT_FIELDS
        haskey(names, param) || continue
        key = getfield(inputs, field)
        key isa IS.StaticTimeSeriesKey || return false
        expected = _expected_series_name(device, names, param, direction)
        _require_key_name(device, key, expected)
        PSY.has_time_series(device, PSY.SingleTimeSeries, expected) || return false
    end
    uigf_required = haskey(names, EnergyUIGFTimeSeriesParameter) && is_semi_scheduled(device)
    if uigf_required
        telemetry.uigf isa IS.StaticTimeSeriesKey || return false
        _require_key_name(device, telemetry.uigf, NEM_TELEMETRY_SERIES.uigf)
    end
    return true
end


# The energy availability parameters; PowerSimulations.jl reads each from one series name per device type.
const _AVAILABILITY_PARAMETERS = (
    EnergyMaxAvailTimeSeriesParameter, PSI.ActivePowerOutTimeSeriesParameter, PSI.ActivePowerInTimeSeriesParameter,
)

# The `MAXAVAIL` series name `param` reads on `device`: its energy bid side's, per direction for a battery.
function _availability_series_name(device, param)
    side = if device isa PSY.Storage
        param === PSI.ActivePowerInTimeSeriesParameter ? OfferSide.LOAD : OfferSide.GEN
    else
        only(energy_offer_sides(device))
    end
    return _max_avail_series_name(side)
end


# The parameter type, ramp direction (`nothing` outside the ramp rates) and [`NEMDispatchInputs`](@ref)
# field holding its series key.
const _DERIVED_INPUT_FIELDS = (
    (RampRateTimeSeriesParameter, RampUp(), :ramp_up),
    (RampRateTimeSeriesParameter, RampDown(), :ramp_down),
    (EnergyMaxAvailTimeSeriesParameter, nothing, :energy_availability),
    (PSI.ActivePowerOutTimeSeriesParameter, nothing, :energy_availability),
    (PSI.ActivePowerInTimeSeriesParameter, nothing, :energy_availability_decremental),
)

# The series name `param` reads on `device`, for the ramp `direction` of a ramp rate.
function _expected_series_name(device, names, param, direction::Union{RampUp, RampDown})
    return _ramp_series_name(direction)
end

function _expected_series_name(device, names, param, ::Nothing)
    return param in _AVAILABILITY_PARAMETERS ? _availability_series_name(device, param) : names[param]
end

# Adds one ramp-rate parameter of `direction`, read from the series the devices' dispatch inputs name.
function _add_ramp_rate_parameter!(container, devices, model, direction::Union{RampUp, RampDown})
    PSI.add_parameters!(
        container, RampRateTimeSeriesParameter, devices, model;
        meta = _ramp_meta(direction),
        time_series_name = _inputs_series_name(first(devices), _ramp_input_field(direction)),
    )
    return
end

# Adds both ramp-rate parameters when the model registers them.
function _add_ramp_rate_parameters!(container, devices, model)
    haskey(PSI.get_time_series_names(model), RampRateTimeSeriesParameter) || return
    _add_ramp_rate_parameter!(container, devices, model, RampUp())
    _add_ramp_rate_parameter!(container, devices, model, RampDown())
    return
end


"""
    _dispatch_inputs_attribute(device) -> NEMDispatchInputs

`device`'s [`NEMDispatchInputs`](@ref), attached by [`set_effective_offers!`](@ref). Throws an
`ArgumentError` naming `device` when it carries none.

# Arguments
- `device`: the NEM dispatch device.

# Returns
A [`NEMDispatchInputs`](@ref).
"""
function _dispatch_inputs_attribute(device)
    attributes = PSY.get_supplemental_attributes(NEMDispatchInputs, device)::Vector{NEMDispatchInputs}
    isempty(attributes) && throw(
        ArgumentError(
            "\"$(PSY.get_name(device))\" carries no NEMDispatchInputs; call set_effective_offers! on the System.",
        ),
    )
    return only(attributes)
end


# The name of the derived series behind `field` of `device`'s inputs. Throws an `ArgumentError` naming
# `device` when the input is absent.
function _inputs_series_name(device, field::Symbol)
    key = getfield(_dispatch_inputs_attribute(device), field)
    isnothing(key) && throw(
        ArgumentError("\"$(PSY.get_name(device))\" has no derived $(field) series; call set_effective_offers! on the System."),
    )
    return PSY.get_name(key)
end


# Throws an `ArgumentError` naming `device` unless the series behind `key` is named `expected`.
function _require_key_name(device, key::IS.TimeSeriesKey, expected::AbstractString)
    name = PSY.get_name(key)
    name == expected || throw(
        ArgumentError("\"$(PSY.get_name(device))\": its unit data holds the series \"$name\", expected \"$expected\""),
    )
    return
end


"""
    PSI.get_initial_conditions_device_model(::PSI.OperationModel, ::PSI.DeviceModel{T, <:AbstractNEMDispatch})

Device model PowerSimulations requires of every formulation for an initial-conditions sub-model;
[`NEMReplayDispatch`](@ref) builds none.

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

Argument stage for [`AbstractNEMDispatch`](@ref): the active power variable, the separate energy
limit and ramp parameters, the offer-total violation variables, and the device's contribution to the
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
        is_non_scheduled_load(d) || continue
        for t in PSI.get_time_steps(container)
            JuMP.fix(PSI.get_variable(container, PSI.ActivePowerVariable(), T)[PSY.get_name(d), t], 0.0; force = true)
        end
    end
    _add_device_unit_slacks!(container, EnergyLimitMaxAvailVariant(), devices)
    semi = _semi_scheduled_devices(devices)
    _add_device_unit_slacks!(container, EnergyLimitUIGFVariant(), semi)

    _add_ramp_rate_parameters!(container, devices, model)
    haskey(PSI.get_time_series_names(model), EnergyMaxAvailTimeSeriesParameter) &&
        PSI.add_parameters!(container, EnergyMaxAvailTimeSeriesParameter, devices, model)
    PSI.add_parameters!(
        container, InitialPowerTimeSeriesParameter, devices, model;
        time_series_name = _INITIAL_MW_SEED_SERIES,
    )
    any(is_semi_scheduled, devices) &&
        PSI.add_parameters!(container, EnergyUIGFTimeSeriesParameter, devices, model)
    _add_fixed_load_arguments!(container, devices, model)

    for variant in _ENERGY_OFFER_SLACK_VARIANTS
        _add_energy_offer_slack_variables!(container, variant, devices)
    end
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
constraint and the energy offer bands and their objective.

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
    PSI.add_constraints!(container, EnergyFixedLoadConstraint, devices, model, network_model)

    PSI.add_constraints!(container, PSI.RampConstraint, PSI.ActivePowerVariable, devices, model, network_model)

    PSI.add_feedforward_constraints!(container, model, devices)
    PSI.objective_function!(container, devices, model, PSI.get_network_formulation(network_model))
    PSI.add_constraint_dual!(container, sys, model)
    return
end


const _SETTER_REMEDY = "Build the System with nem_system(db, NEMDEConfiguration(); date_range) over the model's date range first."


"""
    PSI.add_constraints!(container, ::Type{PSI.RampConstraint}, ::Type{PSI.ActivePowerVariable}, devices, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_model)

Holds each device's active power within its per-interval ramp rates of the base its formulation
measures against, through [`_add_nem_ramp_constraints!`](@ref).

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
    power = PSI.get_variable(container, PSI.ActivePowerVariable(), T)
    _add_nem_ramp_constraints!(
        container, T, devices, (name, t) -> power[name, t],
        names -> _ramp_base_accessor(container, D, T, names, power),
    )
    return
end


"""
    _add_nem_ramp_constraints!(container, T, devices, net_at, base_accessor)

Holds each device's dispatch `net_at(name, t)` within its per-interval ramp rates of its base.
Rates are read from the `"ramp_up_rate"` and `"ramp_down_rate"` parameters in system-base per-unit
per minute and multiplied by the interval length in minutes. Each `PSI.RampConstraint` row carries a
[`NEMUnitSlack`](@ref) of the `unit_ramp_up` or `unit_ramp_down` variant, priced at [`UNIT_RAMP_CVP_FACTOR`](@ref)
times the Market Price Cap, so conflicts with the availability limits are resolved through the
competing violation costs.

# Arguments
- `container`: the `PSI.OptimizationContainer` being built.
- `T`: the component type of `devices`.
- `devices`: the devices whose rows are added.
- `net_at`: `(name, t) ->` the device's dispatch expression at interval `t`.
- `base_accessor`: `names ->` a `(name, t) ->` accessor of the base each row measures against.

# Returns
`nothing`.
"""
function _add_nem_ramp_constraints!(container::PSI.OptimizationContainer, ::Type{T}, devices, net_at, base_accessor) where {T}
    time_steps = PSI.get_time_steps(container)
    jump_model = PSI.get_jump_model(container)
    minutes = 60 * interval_hours(PSI.get_resolution(container))

    names = [PSY.get_name(d) for d in devices]
    isempty(names) && return

    up_rate, up_covered = _ts_parameter_accessor(container, RampRateTimeSeriesParameter, T, _ramp_meta(RampUp()))
    down_rate, down_covered = _ts_parameter_accessor(container, RampRateTimeSeriesParameter, T, _ramp_meta(RampDown()))
    _require_coverage(
        names, "no ramp rate time series", _SETTER_REMEDY, up_covered, down_covered,
    )

    con_up = PSI.add_constraints_container!(
        container, PSI.RampConstraint(), T, names, time_steps; meta = "up",
    )
    con_dn = PSI.add_constraints_container!(
        container, PSI.RampConstraint(), T, names, time_steps; meta = "dn",
    )

    slack_up = _add_ramp_slack!(container, UnitRampUpVariant(), T, names, time_steps)
    slack_dn = _add_ramp_slack!(container, UnitRampDownVariant(), T, names, time_steps)

    base_at = base_accessor(names)
    for name in names, t in time_steps
        base = base_at(name, t)
        net = net_at(name, t)
        con_up[name, t] = JuMP.@constraint(jump_model, net - base - slack_up[name, t] <= up_rate(name, t) * minutes)
        con_dn[name, t] = JuMP.@constraint(jump_model, base - net - slack_dn[name, t] <= down_rate(name, t) * minutes)
    end
    return
end


# The elastic slack of a ramp row, built and priced at its variant's CVP factor.
function _add_ramp_slack!(container::PSI.OptimizationContainer, variant::_UnitRampVariant, ::Type{T}, names, time_steps) where {T}
    return _add_cvp_slack!(
        container, NEMUnitSlack, T, names, time_steps, _nem_unit_slack_cvp(variant);
        meta = _nem_unit_slack_meta(variant), label = _nem_unit_slack_label(variant),
    )
end


# Parameter arrays are keyed by time-series UUID, not device name.
function _ts_parameter_accessor(container, ::Type{P}, ::Type{T}, meta::String = "") where {P <: PSI.TimeSeriesParameter, T}
    param_container = PSI.get_parameter(container, P(), T, meta)
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
            "NEMReplayDispatch: the device model registers no initial-power parameter, so the " *
                "ramp has no base to measure against",
        ),
    )
    initial, covered = _ts_parameter_accessor(container, InitialPowerTimeSeriesParameter, T)
    _require_coverage(names, "no initial-power time series", _SETTER_REMEDY, covered)
    return initial
end


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

Prices an [`AbstractNEMDispatch`](@ref) device's dispatch on its own submitted energy offer
bands (`_add_energy_offer_bands!`), so the objective is the device's own bid stack.

# Returns
`nothing`.
"""
function PSI.objective_function!(
        container::PSI.OptimizationContainer,
        devices::IS.FlattenIteratorWrapper{T},
        model::PSI.DeviceModel{T, D},
        ::Type{<:PM.AbstractPowerModel},
    ) where {T <: PSY.StaticInjection, D <: AbstractNEMDispatch}
    _check_energy_offer_sides(devices)
    foreach(side -> _add_energy_offer_bands!(container, devices, model, side), _energy_offer_sides(T))
    _add_device_unit_slack_costs!(container, EnergyLimitMaxAvailVariant(), devices)
    _add_device_unit_slack_costs!(container, EnergyLimitUIGFVariant(), _semi_scheduled_devices(devices))
    _add_fixed_load_costs!(container, devices, T)
    for variant in _ENERGY_OFFER_SLACK_VARIANTS
        _add_energy_offer_slack_costs!(container, variant, devices)
    end
    return
end


"""
    nem_dispatch_participants(sys)

The component types in `sys` that participate in a NEM dispatch: any
`PowerSystems.StaticInjection` with at least one component satisfying
[`_has_nem_dispatch_limits`](@ref) for [`NEMReplayDispatch`](@ref).

# Arguments
- `sys`: the `PowerSystems.System` to inspect.

# Returns
A sorted `Vector` of component types.
"""
function nem_dispatch_participants(sys)
    types = Set{DataType}()
    for device in PSY.get_components(PSY.StaticInjection, sys)
        _has_nem_dispatch_limits(device) || continue
        push!(types, typeof(device))
    end
    return sort!(collect(types); by = string)
end


"""
    set_nem_dispatch_models!(template, sys; tie_breaks = true)

Sets [`NEMReplayDispatch`](@ref) as the device model for every dispatch participant in `sys`, and, when
`sys` carries the [`EnergyTieBreak`](@ref) of [`set_effective_offers!`](@ref), its
[`TieBreakMarket`](@ref) service model, which dispatches price-tied energy bands pro rata. Without it
ties resolve to an arbitrary solver vertex.

# Arguments
- `template`: the `PowerSimulations.ProblemTemplate` to mutate.
- `sys`: the `PowerSystems.System` whose participants are read, via
  [`nem_dispatch_participants`](@ref). A participant without its dispatch series fails the build by name.
- `tie_breaks`: when `false`, no tie-break service model is set.

# Returns
The types the formulation was set for, as a `Vector`.
"""
function set_nem_dispatch_models!(template, sys; tie_breaks::Bool = true)
    types = nem_dispatch_participants(sys)
    isempty(types) && throw(
        ArgumentError(
            "no dispatch participants in this System: build it with nem_system(db, NEMDEConfiguration(); date_range) over the " *
                "model's date range first",
        ),
    )
    foreach(T -> PSI.set_device_model!(template, T, NEMReplayDispatch), types)
    if tie_breaks && !isnothing(PSY.get_component(EnergyTieBreak, sys, TIE_BREAK_SERVICE_NAME))
        PSI.set_service_model!(
            template, TIE_BREAK_SERVICE_NAME, PSI.ServiceModel(EnergyTieBreak, TieBreakMarket, TIE_BREAK_SERVICE_NAME),
        )
    end
    return types
end
