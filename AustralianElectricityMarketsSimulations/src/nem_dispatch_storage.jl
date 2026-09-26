"""
    StorageInputDevicePower

Initial condition type for a [`AbstractNEMDispatch`](@ref) battery's charging-side power,
paired with `PowerSimulations.DevicePower` (the discharging side) so
[`NEMLookaheadDispatch`](@ref) can measure interval 1's net ramp against the initial-conditions
sub-model's solved `Out - In`.
"""
struct StorageInputDevicePower <: PSI.InitialConditionType end

#! format: off
PSI.get_variable_binary(::PSI.ActivePowerOutVariable, ::Type{<:PSY.Storage}, ::AbstractNEMDispatch) = false
PSI.get_variable_binary(::PSI.ActivePowerInVariable, ::Type{<:PSY.Storage}, ::AbstractNEMDispatch) = false
PSI.get_variable_multiplier(::PSI.ActivePowerOutVariable, ::Type{<:PSY.Storage}, ::AbstractNEMDispatch) = 1.0
PSI.get_variable_multiplier(::PSI.ActivePowerInVariable, ::Type{<:PSY.Storage}, ::AbstractNEMDispatch) = -1.0
PSI.get_variable_lower_bound(::PSI.ActivePowerOutVariable, ::PSY.Storage, ::AbstractNEMDispatch) = 0.0
PSI.get_variable_lower_bound(::PSI.ActivePowerInVariable, ::PSY.Storage, ::AbstractNEMDispatch) = 0.0
PSI.get_variable_upper_bound(::PSI.ActivePowerOutVariable, d::PSY.Storage, ::AbstractNEMDispatch) = PSY.get_output_active_power_limits(d).max
PSI.get_variable_upper_bound(::PSI.ActivePowerInVariable, d::PSY.Storage, ::AbstractNEMDispatch) = PSY.get_input_active_power_limits(d).max

PSI.initial_condition_default(::PSI.DevicePower, d::PSY.Storage, ::AbstractNEMDispatch) = max(PSY.get_active_power(d), 0.0)
PSI.initial_condition_variable(::PSI.DevicePower, ::PSY.Storage, ::AbstractNEMDispatch) = PSI.ActivePowerOutVariable()
PSI.initial_condition_default(::StorageInputDevicePower, d::PSY.Storage, ::AbstractNEMDispatch) = max(-PSY.get_active_power(d), 0.0)
PSI.initial_condition_variable(::StorageInputDevicePower, ::PSY.Storage, ::AbstractNEMDispatch) = PSI.ActivePowerInVariable()
#! format: on

"""
    PSI.get_default_time_series_names(::Type{<:PSY.Storage}, ::Type{<:AbstractNEMDispatch})

Registers the time series [`AbstractNEMDispatch`](@ref) reads as parameters for a battery: the
ramp and initial-power series, without the `"max_active_power"` series generators register. A
battery's per-direction availability is read separately, from
[`get_storage_energy_max_avail`](@ref).

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
    )
end

"""
    PSI.construct_device!(container, sys, ::PSI.ArgumentConstructStage, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_model) where {T <: PSY.Storage}

Argument stage for a battery under [`AbstractNEMDispatch`](@ref): the per-direction active
power variables, the ramp parameters, the initial conditions [`NEMLookaheadDispatch`](@ref)
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

    for param in (
            RampUpRateTimeSeriesParameter,
            RampDownRateTimeSeriesParameter,
            InitialPowerTimeSeriesParameter,
        )
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

    _check_storage_dispatch_envelope(container, devices, model)
    _add_storage_availability_constraints!(container, devices, model)
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

"""
    _add_storage_availability_constraints!(container, devices, model)

Bounds each battery's `PowerSimulations.ActivePowerOutVariable`/`ActivePowerInVariable` above
by [`get_storage_energy_max_avail`](@ref)'s per-direction energy bid `MAXAVAIL`, read once at
build over the model's own window. A battery with no `MAXAVAIL` series attached is left
unconstrained on both sides.

# Returns
`nothing`.
"""
function _add_storage_availability_constraints!(container, devices, model::PSI.DeviceModel{T}) where {T}
    isempty(devices) && return
    time_steps = PSI.get_time_steps(container)
    initial_time = PSI.get_initial_time(container)
    horizon = length(time_steps)
    jump_model = PSI.get_jump_model(container)
    out = PSI.get_variable(container, PSI.ActivePowerOutVariable(), T)
    in_ = PSI.get_variable(container, PSI.ActivePowerInVariable(), T)

    names = String[]
    gen_ceiling = Dict{String, Vector{Float64}}()
    load_ceiling = Dict{String, Vector{Float64}}()
    for d in devices
        avail = get_storage_energy_max_avail(d, initial_time, horizon)
        isnothing(avail) && continue
        name = PSY.get_name(d)
        push!(names, name)
        gen_ceiling[name] = avail.gen
        load_ceiling[name] = avail.load
    end
    isempty(names) && return

    con_out = PSI.add_constraints_container!(
        container, PSI.ActivePowerVariableLimitsConstraint(), T, names, time_steps; meta = "out",
    )
    con_in = PSI.add_constraints_container!(
        container, PSI.ActivePowerVariableLimitsConstraint(), T, names, time_steps; meta = "in",
    )
    for name in names, t in time_steps
        con_out[name, t] = JuMP.@constraint(jump_model, out[name, t] <= gen_ceiling[name][t])
        con_in[name, t] = JuMP.@constraint(jump_model, in_[name, t] <= load_ceiling[name][t])
    end
    return
end

"""
    _add_storage_ramp_constraints!(container, devices, model)

Holds each battery's net `Out - In` within its per-interval ramp rates of the base its
formulation measures against, mirroring [`PSI.add_constraints!`](@ref)'s generator ramp
constraint.

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

    base_at = _storage_ramp_base_accessor(container, D, T, names, out, in_)
    for name in names, t in time_steps
        base = base_at(name, t)
        net = out[name, t] - in_[name, t]
        con_up[name, t] = JuMP.@constraint(jump_model, net - base <= up_rate(name, t) * minutes)
        con_dn[name, t] = JuMP.@constraint(jump_model, base - net <= down_rate(name, t) * minutes)
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

# A ramp window that never reaches the availability envelope is infeasible; report it at build.
function _check_storage_dispatch_envelope(container, devices, model)
    PSI.get_formulation(model) === NEMReplayDispatch || return
    haskey(PSI.get_time_series_names(model), InitialPowerTimeSeriesParameter) || return
    isempty(devices) && return
    T = typeof(first(devices))
    time_steps = PSI.get_time_steps(container)
    minutes = PSI._get_minutes_per_period(container)
    initial_time = PSI.get_initial_time(container)
    horizon = length(time_steps)
    initial, initial_covered = _ts_parameter_accessor(container, InitialPowerTimeSeriesParameter, T)
    down_rate, down_covered = _ts_parameter_accessor(container, RampDownRateTimeSeriesParameter, T)
    up_rate, up_covered = _ts_parameter_accessor(container, RampUpRateTimeSeriesParameter, T)
    problems = String[]
    for d in devices
        name = PSY.get_name(d)
        all(name in c for c in (initial_covered, down_covered, up_covered)) || continue
        avail = get_storage_energy_max_avail(d, initial_time, horizon)
        isnothing(avail) && continue
        for t in time_steps
            floor_mw = JuMP.value(initial(name, t)) - JuMP.value(down_rate(name, t)) * minutes
            ceiling_mw = JuMP.value(initial(name, t)) + JuMP.value(up_rate(name, t)) * minutes
            if floor_mw > avail.gen[t] + _RAMP_FLOOR_TOLERANCE
                push!(
                    problems,
                    "$name at interval $t: ramp-down floor $floor_mw exceeds generation availability $(avail.gen[t])",
                )
                break
            elseif ceiling_mw < -avail.load[t] - _RAMP_FLOOR_TOLERANCE
                push!(
                    problems,
                    "$name at interval $t: ramp-up ceiling $ceiling_mw is below negative load availability $(-avail.load[t])",
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
