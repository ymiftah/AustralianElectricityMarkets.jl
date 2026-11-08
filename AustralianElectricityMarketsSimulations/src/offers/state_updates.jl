# Per-step updates of the parameters that read a unit's or link's state: the ramp base, the ramp
# rates, the energy availability limits, the fixed-loading target and invoked flag, the FCAS
# effective offers and regulation ramping limits, and an MNSP's metered flow and ramp envelope.
# PowerSimulations clears the objective's variant terms first.

"""
    _step_stamp(model, t) -> DateTime

The stamp of step `t` of `model`'s current horizon; `t = 1` is the horizon's first step.

# Arguments
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `t`: the step index.

# Returns
A `DateTime`.
"""
function _step_stamp(model::PSI.OperationModel, t::Integer)
    return PSI.get_current_timestamp(model) + (t - 1) * PSI.get_resolution(model)
end


"""
    _update_state_parameters!(value_at, container, model, key) -> nothing

Writes `value_at(device, stamp)` into every row of the time-series parameter `key` at every step of
`model`'s horizon, in the units its multiplier scales. Only the devices the parameter was built for
are written. Throws when a value is not finite.

# Arguments
- `value_at`: `(device, stamp) -> Float64`, the value before the multiplier.
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter to update.

# Returns
`nothing`.
"""
function _update_state_parameters!(value_at, container::PSI.OptimizationContainer, model::PSI.OperationModel, key::PSI.ParameterKey{P, T}) where {P, T}
    parameter_array = PSI.get_parameter_array(container, key)
    parent_param = PSI.get_parameter_array_data(PSI.get_parameter(container, key))
    attributes = PSI.get_parameter_attributes(container, key)
    steps = PSI.get_time_steps(container)
    system = PSI.get_system(model)
    for (name, uuid) in attributes.component_name_to_ts_uuid
        device = PSY.get_component(T, system, name)
        i = parameter_array.lookup[1][uuid]
        for t in steps
            stamp = _step_stamp(model, t)
            value = Float64(value_at(device, stamp))
            isfinite(value) || error(
                "The value of $(nameof(P)) for \"$(name)\" at $(stamp) is not finite. " *
                    "Check that the unit's state and bids are valid.",
            )
            PSI._set_param_value_at!(parent_param, value, i, t)
        end
    end
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`InitialPowerTimeSeriesParameter`](@ref) from each device's [`NEMUnitState`](@ref) at the
step, read through the configured [`StateSource`](@ref). The value is the unit's starting MW, which the parameter's
multiplier converts to system-base per-unit.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{InitialPowerTimeSeriesParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_state_parameters!(container, model, key) do device, stamp
        return unit_state(_state_source(), device, stamp).initial_mw
    end
    return
end


# The value of `device`'s series `key` at `stamp`.
function _key_value(device, key::IS.TimeSeriesKey, stamp::DateTime)
    return Float64(only(IS.get_time_series_values(device, key; start_time = stamp, len = 1)))
end


# The energy availability bound of one side at one interval, system-base per-unit. AEMO's Dispatch
# Procedure (SO_OP_3705) section 9 makes the ramp-down rate the furthest the resource can fall from
# the starting output, so a non-storage device's bound is that floor. A storage device keeps the bid
# availability: its net ramp row prices a starting output outside that band.
function _max_avail_bound(availability::Real, state::NEMUnitState, device, down_rate::Real, hours::Real, base::Real)
    isfinite(state.initial_mw) || return Float64(availability)
    device isa PSY.Storage && return Float64(availability)
    rate = isfinite(down_rate) ? down_rate * base * 60 : 0.0
    return max_active_power_floor(availability * base, rate, hours, state) / base
end


# The live availability bound of `side` at `stamp`, system-base per-unit, from the raw availability
# series, the effective ramp-down rate and the unit's state.
function _energy_max_avail_at(device, side::OfferSide, stamp::DateTime, hours::Real, base::Real)
    inputs = _dispatch_inputs_attribute(device)
    key = side == OfferSide.LOAD ? inputs.energy_availability_decremental : inputs.energy_availability
    key isa IS.TimeSeriesKey || throw(
        ArgumentError(
            "\"$(PSY.get_name(device))\" has no $(side)-side energy availability series; call set_effective_offers! on the System.",
        ),
    )
    down_rate = isnothing(inputs.ramp_down) ? NaN : _key_value(device, inputs.ramp_down, stamp)
    return _max_avail_bound(
        _key_value(device, key, stamp), unit_state(_state_source(), device, stamp), device, down_rate, hours, base,
    )
end


# The bid ramp rate of `side` at `stamp`, MW/min; `NaN` without a bid or a published rate.
function _bid_ramp_rate_at(device, side::OfferSide, field::Symbol, stamp::DateTime)
    cost = _nem_offer_cost(device)
    isnothing(cost) && return NaN
    bid = _energy_bid(cost, side)
    isnothing(bid) && return NaN
    value = _state_value(device, bid, field, stamp)
    return isnothing(value) ? NaN : Float64(value)
end


# The effective ramp limit of one direction at `stamp`, system-base per-unit per minute: a device bid
# on both sides takes the composite cross-zero rate (AEMO Dispatch Procedure SO_OP_3705 Appendix C),
# every other device its per-side bid rate, each capped by the telemetered limit. A non-scheduled load
# and an interval the inputs do not cover are held at zero, as at build.
function _ramp_rate_at(device, up::Bool, stamp::DateTime, resolution, base::Real)
    AustralianElectricityMarkets.is_non_scheduled_load(device) && return 0.0
    telemetry = getproperty(device, :telemetry)
    telemetry_value = _state_value(device, telemetry, up ? :ramp_up_limit : :ramp_down_limit, stamp)
    telemetry_rate = isnothing(telemetry_value) ? NaN : Float64(telemetry_value)
    rate = if device isa PSY.Storage
        minutes = Dates.value(Millisecond(resolution)) / 60000
        up_rate, down_rate = composite_ramp_rates(
            _bid_ramp_rate_at(device, OfferSide.GEN, :roc_up, stamp),
            _bid_ramp_rate_at(device, OfferSide.GEN, :roc_down, stamp),
            _bid_ramp_rate_at(device, OfferSide.LOAD, :roc_up, stamp),
            _bid_ramp_rate_at(device, OfferSide.LOAD, :roc_down, stamp),
            minutes, unit_state(_state_source(), device, stamp),
        )
        up ? up_rate : down_rate
    else
        _bid_ramp_rate_at(device, first(energy_offer_sides(device)), up ? :roc_up : :roc_down, stamp)
    end
    limit = effective_ramp_limit(rate, telemetry_rate)
    return isfinite(limit) ? limit / 60 / base : 0.0
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`RampUpRateTimeSeriesParameter`](@ref) from each device's energy bids and
[`NEMUnitState`](@ref) at the step, read through the configured [`StateSource`](@ref), in system-base
per-unit per minute: the composite cross-zero rate of a device bid on both sides or its per-side bid
rate, capped by the telemetered limit.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{RampUpRateTimeSeriesParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_state_parameters!(container, model, key) do device, stamp
        return _ramp_rate_at(device, true, stamp, PSI.get_resolution(model), PSI.get_base_power(container))
    end
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`RampDownRateTimeSeriesParameter`](@ref) from each device's energy bids and
[`NEMUnitState`](@ref) at the step, read through the configured [`StateSource`](@ref), in system-base
per-unit per minute: the composite cross-zero rate of a device bid on both sides or its per-side bid
rate, capped by the telemetered limit.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{RampDownRateTimeSeriesParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_state_parameters!(container, model, key) do device, stamp
        return _ramp_rate_at(device, false, stamp, PSI.get_resolution(model), PSI.get_base_power(container))
    end
    return
end


# The metered flow of `device`'s MNSP link at `stamp`, MW, from the observed state the link carries.
function _mnsp_initial_flow(::ObservedState, device::PSY.AreaInterchange, stamp::DateTime)
    observed = only(PSY.get_supplemental_attributes(NEMMNSPObservedState, device))
    return Float64(_state_value(device, observed, :initial_flow, stamp))
end

function _mnsp_initial_flow(::SimulatedState, device::PSY.AreaInterchange, stamp::DateTime)
    throw(ArgumentError("SimulatedState is not implemented yet, so the MNSP flow of $(PSY.get_name(device)) cannot be simulated"))
end


# The forward or reverse ramp rate of `device`'s link at `stamp`, MW/min: the envelope
# `mnsp_ramp_envelope` opens about the metered flow, divided by the interval so the ramp row's
# `InitialFlow ± minutes × rate` form reproduces it. AEMO's MMS Dispatch Algorithm limits an MNSP's
# target flow to its metered flow plus the forward bid ramp over the interval, and minus the reverse.
function _mnsp_ramp_rate_at(device::PSY.AreaInterchange, forward::Bool, stamp::DateTime, minutes::Real)
    initial = _mnsp_initial_flow(_state_source(), device, stamp)
    up = _key_value(device, _mnsp_bid(device, "forward").ramp_up, stamp)
    down = _key_value(device, _mnsp_bid(device, "reverse").ramp_up, stamp)
    upper, lower = mnsp_ramp_envelope(initial, up, down, minutes)
    return forward ? (upper - initial) / minutes : (initial - lower) / minutes
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`MNSPInitialFlowParameter`](@ref) from each link's metered flow at the step, read through
the configured [`StateSource`](@ref), in MW: the starting point of the [`mnsp_ramp_envelope`](@ref)
the formulation builds each ramp row from.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the link's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{MNSPInitialFlowParameter, PSY.AreaInterchange},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    _update_state_parameters!(container, model, key) do device, stamp
        return _mnsp_initial_flow(_state_source(), device, stamp)
    end
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`MNSPForwardRampRateParameter`](@ref) from each link's metered flow and forward and
reverse bid ramp rates at the step, read through the configured [`StateSource`](@ref), in MW/min:
the forward rate of the [`mnsp_ramp_envelope`](@ref).

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the link's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{MNSPForwardRampRateParameter, PSY.AreaInterchange},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    minutes = Dates.value(Millisecond(PSI.get_resolution(model))) / 60000
    _update_state_parameters!(container, model, key) do device, stamp
        return _mnsp_ramp_rate_at(device, true, stamp, minutes)
    end
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`MNSPReverseRampRateParameter`](@ref) from each link's metered flow and forward and
reverse bid ramp rates at the step, read through the configured [`StateSource`](@ref), in MW/min:
the reverse rate of the [`mnsp_ramp_envelope`](@ref).

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the link's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{MNSPReverseRampRateParameter, PSY.AreaInterchange},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    minutes = Dates.value(Millisecond(PSI.get_resolution(model))) / 60000
    _update_state_parameters!(container, model, key) do device, stamp
        return _mnsp_ramp_rate_at(device, false, stamp, minutes)
    end
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`EnergyMaxAvailTimeSeriesParameter`](@ref) from each device's generation-side energy
availability and [`NEMUnitState`](@ref) at the step, read through the configured
[`StateSource`](@ref), in system-base per-unit: the bid availability, raised to the ramp-down floor
([`max_active_power_floor`](@ref)) for a non-storage device and unchanged for a storage device.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{EnergyMaxAvailTimeSeriesParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_state_parameters!(container, model, key) do device, stamp
        return _energy_max_avail_at(
            device, OfferSide.GEN, stamp, interval_hours(PSI.get_resolution(model)), PSI.get_base_power(container),
        )
    end
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes `PowerSimulations.ActivePowerOutTimeSeriesParameter` from each battery's generation-side
energy availability at the step, read through the configured [`StateSource`](@ref), in system-base
per-unit: the bid availability. The net ramp row prices a starting output outside the availability
band, so the bound is not raised to it.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{PSI.ActivePowerOutTimeSeriesParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_availability_parameters!(container, model, key, OfferSide.GEN)
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes `PowerSimulations.ActivePowerInTimeSeriesParameter` from each battery's load-side energy
availability at the step, read through the configured [`StateSource`](@ref), in system-base per-unit:
the bid availability. The net ramp row prices a starting output outside the availability band, so
the bound is not raised to it.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{PSI.ActivePowerInTimeSeriesParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_availability_parameters!(container, model, key, OfferSide.LOAD)
    return
end


# The shared body of the two directional availability updates.
function _update_availability_parameters!(container, model, key, side::OfferSide)
    _update_state_parameters!(container, model, key) do device, stamp
        return _energy_max_avail_at(
            device, side, stamp, interval_hours(PSI.get_resolution(model)), PSI.get_base_power(container),
        )
    end
    return
end


# The raw `FIXEDLOAD` of `device`'s `side` energy bid at `stamp`, MW; `NaN` when the bid has none.
function _fixed_load_mw(device, side::OfferSide, stamp::DateTime)
    cost = _nem_offer_cost(device)
    bid = isnothing(cost) ? nothing : _energy_bid(cost, side)
    isnothing(bid) && return NaN
    value = _state_value(device, bid, :fixed_load, stamp)
    return isnothing(value) ? NaN : Float64(value)
end


# The fixed-loading target on the net-injection axis at `stamp`, MW, and whether either side applies.
function _fixed_load_step(device, stamp::DateTime; source::StateSource = _state_source())
    state = unit_state(source, device, stamp)
    gen = _fixed_load_mw(device, OfferSide.GEN, stamp)
    load = _fixed_load_mw(device, OfferSide.LOAD, stamp)
    target = if device isa PSY.Storage
        effective_fixed_load(gen, state) - effective_fixed_load(load, state)
    else
        effective_fixed_load(gen, state) + effective_fixed_load(load, state)
    end
    return (; target, invoked = fixed_load_invoked(gen, state) || fixed_load_invoked(load, state))
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`FixedLoadTimeSeriesParameter`](@ref) from each device's energy bids and
[`NEMUnitState`](@ref) at the step, read through the configured [`StateSource`](@ref): the net injection at the
device's [`effective_fixed_load`](@ref), in system-base per-unit. A storage device's load side is
subtracted from its generation side; the loading is zero wherever it is not invoked.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{FixedLoadTimeSeriesParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    base_power = PSI.get_base_power(container)
    _update_state_parameters!(container, model, key) do device, stamp
        return _fixed_load_step(device, stamp).target / base_power
    end
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`FixedLoadInvokedTimeSeriesParameter`](@ref) from each device's energy bids and
[`NEMUnitState`](@ref) at the step, read through the configured [`StateSource`](@ref): `1` where either side's
loading applies and `0` otherwise.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{FixedLoadInvokedTimeSeriesParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_state_parameters!(container, model, key) do device, stamp
        return _fixed_load_step(device, stamp).invoked ? 1.0 : 0.0
    end
    return
end


# The bid type and offer side a parameter's meta names, `"<BIDTYPE>"` or `"<BIDTYPE>_decremental"`.
function _fcas_meta_offer(meta::AbstractString)
    suffix = "_decremental"
    decremental = endswith(meta, suffix)
    name = decremental ? meta[1:(end - length(suffix))] : meta
    return BidType(name), decremental
end


"""
    _update_fcas_parameters!(field_slice, kind, container, model, key) -> nothing

Writes the FCAS effective offer or regulation ramping limit of every device the parameter was built
for at every step of `model`'s horizon, recomputed through [`_fcas_effective_values`](@ref) from the
unit's [`NEMUnitState`](@ref) at the step, read through the configured [`StateSource`](@ref), and its
[`_FCASWindow`](@ref). The values are per-unit of the system base, as the series were attached.
`field_slice` selects the parameter's own entries of one offer or ramping-limit element.

# Arguments
- `field_slice`: `element -> value`, the parameter's entries of one element.
- `kind`: `:offer` for an effective offer parameter, `:ramping` for a ramping limit parameter.
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter; its meta names the market and side.

# Returns
`nothing`.
"""
function _update_fcas_parameters!(
        field_slice::Function, kind::Symbol, container::PSI.OptimizationContainer,
        model::PSI.OperationModel, key::PSI.ParameterKey{P, T},
    ) where {P, T}
    parameter_array = PSI.get_parameter_array(container, key)
    parent_param = PSI.get_parameter_array_data(PSI.get_parameter(container, key))
    attributes = PSI.get_parameter_attributes(container, key)
    steps = PSI.get_time_steps(container)
    system = PSI.get_system(model)
    bid_type, decremental = _fcas_meta_offer(key.meta)
    PSY.with_units_base(system, "SYSTEM_BASE") do
        base = PSY.get_base_power(system)
        inactive = FCAS_INACTIVE_LIMIT_MW / base
        window = _FCASWindow(PSI.get_current_timestamp(model), length(steps), PSI.get_resolution(model))
        for (name, uuid) in attributes.component_name_to_ts_uuid
            device = PSY.get_component(T, system, name)
            # AEMO's *FCAS Model in NEMDE* §5 enablement and §6.1/§6.4 ramping read the starting
            # output, so the effective offers and ramping limits are rebuilt from the state here.
            # The FCAS series are per-unit of the system base, so the state is too.
            state = t -> begin
                unit = unit_state(_state_source(), device, _step_stamp(model, t))
                return NEMUnitState(unit.initial_mw / base, unit.dispatch_mode)
            end
            offers, ramping = _fcas_effective_values(
                window, device, bid_type, fcas_bid_direction(device, bid_type), inactive; state,
            )
            values = kind === :ramping ? ramping : offers[decremental]
            i = parameter_array.lookup[1][uuid]
            for t in steps
                PSI._set_param_value_at!(parent_param, field_slice(values[t]), i, t)
            end
        end
    end
    return
end


# The slope parameters set a constraint coefficient through the stock `add_coefficient_target!`
# registration, so a new value only reaches its row once the registered coefficients are rewritten,
# as the stock constraint-coefficient update method does.
function _apply_fcas_slope_coefficients!(container::PSI.OptimizationContainer, key::PSI.ParameterKey)
    PSI._apply_coefficient_targets!(PSI.get_parameter(container, key))
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`FCASOfferLimitParameter`](@ref) from each device's effective FCAS offer and
[`NEMUnitState`](@ref) at the step: `MaxAvail`, `EnablementMin` and `EnablementMax`, per-unit of the
system base.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{FCASOfferLimitParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_fcas_parameters!(v -> [v[1], v[2], v[3]], :offer, container, model, key)
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`FCASBandWidthParameter`](@ref) from each device's effective FCAS offer and
[`NEMUnitState`](@ref) at the step: the ten band widths, per-unit of the system base.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{FCASBandWidthParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_fcas_parameters!(v -> collect(v[6:15]), :offer, container, model, key)
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`FCASUpperSlopeParameter`](@ref) from each device's effective FCAS offer and
[`NEMUnitState`](@ref) at the step: the upper slope coefficient.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{FCASUpperSlopeParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_fcas_parameters!(v -> v[4], :offer, container, model, key)
    _apply_fcas_slope_coefficients!(container, key)
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`FCASLowerSlopeParameter`](@ref) from each device's effective FCAS offer and
[`NEMUnitState`](@ref) at the step: the lower slope coefficient.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{FCASLowerSlopeParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_fcas_parameters!(v -> v[5], :offer, container, model, key)
    _apply_fcas_slope_coefficients!(container, key)
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`FCASRampingLimitParameter`](@ref) from each device's AGC ramping capability and
[`NEMUnitState`](@ref) at the step, through [`fcas_ramping_active`](@ref) and
[`fcas_ramping_limit`](@ref): the joint ramping limit and the battery's BDU ramping limit, per-unit
of the system base.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{FCASRampingLimitParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _update_fcas_parameters!(v -> [v[1], v[2]], :ramping, container, model, key)
    return
end
