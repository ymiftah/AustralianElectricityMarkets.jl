# Per-step updates of the energy parameters: the ramp rates and the fixed loading.

# The bid ramp rate of `side` at `stamp`, MW/min; `NaN` without a bid or a published rate.
function _bid_ramp_rate_at(device, side::OfferSide, field::Val{F}, stamp::DateTime) where {F}
    cost = _nem_offer_cost(device)
    isnothing(cost) && return NaN
    bid = _energy_bid(cost, side)
    isnothing(bid) && return NaN
    value = _state_value(device, bid, field, stamp)
    return isnothing(value) ? NaN : Float64(value)
end


# The effective ramp limit of one direction at `stamp`, system-base per-unit per minute: the
# composite cross-zero rate of a device bid on both sides, capped by the telemetered limit.
function _ramp_rate_at(device, up::Bool, stamp::DateTime, resolution, base::Real)
    AustralianElectricityMarkets.is_non_scheduled_load(device) && return 0.0
    telemetry = _unit_telemetry(device)
    telemetry_value = _state_value(device, telemetry, up ? Val(:ramp_up_limit) : Val(:ramp_down_limit), stamp)
    telemetry_rate = isnothing(telemetry_value) ? NaN : Float64(telemetry_value)
    rate = if device isa PSY.Storage
        minutes = Dates.value(Millisecond(resolution)) / 60000
        up_rate, down_rate = composite_ramp_rates(
            _bid_ramp_rate_at(device, OfferSide.GEN, Val(:roc_up), stamp),
            _bid_ramp_rate_at(device, OfferSide.GEN, Val(:roc_down), stamp),
            _bid_ramp_rate_at(device, OfferSide.LOAD, Val(:roc_up), stamp),
            _bid_ramp_rate_at(device, OfferSide.LOAD, Val(:roc_down), stamp),
            minutes, unit_state(_state_source(), device, stamp),
        )
        up ? up_rate : down_rate
    else
        _bid_ramp_rate_at(device, first(energy_offer_sides(device)), up ? Val(:roc_up) : Val(:roc_down), stamp)
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
Under [`ObservedState`](@ref) the stock PowerSimulations update refreshes it from the series that
[`prepare_replay!`](@ref) attached. Under [`SimulatedState`](@ref), or when the custom path is forced,
it is recomputed from each device's [`NEMUnitState`](@ref) at the step.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, passed to the stock update and not read by the custom one.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{RampUpRateTimeSeriesParameter, T},
        input::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _use_stock_state_update() && return _stock_state_update!(container, model, key, input)
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
Under [`ObservedState`](@ref) the stock PowerSimulations update refreshes it from the series that
[`prepare_replay!`](@ref) attached. Under [`SimulatedState`](@ref), or when the custom path is forced,
it is recomputed from each device's [`NEMUnitState`](@ref) at the step.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, passed to the stock update and not read by the custom one.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{RampDownRateTimeSeriesParameter, T},
        input::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _use_stock_state_update() && return _stock_state_update!(container, model, key, input)
    _update_state_parameters!(container, model, key) do device, stamp
        return _ramp_rate_at(device, false, stamp, PSI.get_resolution(model), PSI.get_base_power(container))
    end
    return
end


# The raw `FIXEDLOAD` of `device`'s `side` energy bid at `stamp`, MW; `NaN` when the bid has none.
function _fixed_load_mw(device, side::OfferSide, stamp::DateTime)
    cost = _nem_offer_cost(device)
    bid = isnothing(cost) ? nothing : _energy_bid(cost, side)
    isnothing(bid) && return NaN
    value = _state_value(device, bid, Val(:fixed_load), stamp)
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
Under [`ObservedState`](@ref) the stock PowerSimulations update refreshes it from the series that
[`prepare_replay!`](@ref) attached. Under [`SimulatedState`](@ref), or when the custom path is forced,
it is recomputed from each device's [`NEMUnitState`](@ref) at the step.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, passed to the stock update and not read by the custom one.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{FixedLoadTimeSeriesParameter, T},
        input::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _use_stock_state_update() && return _stock_state_update!(container, model, key, input)
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
Under [`ObservedState`](@ref) the stock PowerSimulations update refreshes it from the series that
[`prepare_replay!`](@ref) attached. Under [`SimulatedState`](@ref), or when the custom path is forced,
it is recomputed from each device's [`NEMUnitState`](@ref) at the step.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, passed to the stock update and not read by the custom one.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{FixedLoadInvokedTimeSeriesParameter, T},
        input::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _use_stock_state_update() && return _stock_state_update!(container, model, key, input)
    _update_state_parameters!(container, model, key) do device, stamp
        return _fixed_load_step(device, stamp).invoked ? 1.0 : 0.0
    end
    return
end
