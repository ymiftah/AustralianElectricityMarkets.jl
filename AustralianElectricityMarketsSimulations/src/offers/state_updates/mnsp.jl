# Per-step updates of an MNSP's metered flow and ramp envelope.

# The metered flow of `device`'s MNSP link at `stamp`, MW, from the observed state the link carries.
function _mnsp_initial_flow(::ObservedState, device::PSY.AreaInterchange, stamp::DateTime)
    observed = only((PSY.get_supplemental_attributes(NEMMNSPObservedState, device)::Vector{NEMMNSPObservedState}))
    return Float64(_state_value(device, observed, Val(:initial_flow), stamp))
end

function _mnsp_initial_flow(::SimulatedState, device::PSY.AreaInterchange, stamp::DateTime)
    throw(ArgumentError("SimulatedState is not implemented yet, so the MNSP flow of $(PSY.get_name(device)) cannot be simulated"))
end


# The forward or reverse ramp rate of `device`'s link at `stamp`, MW/min: the envelope
# `mnsp_ramp_envelope` opens about the metered flow, divided by the interval so the ramp row's
# `InitialFlow ± minutes × rate` form reproduces it.
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
        input::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    _use_stock_state_update() && return _stock_state_update!(container, model, key, input)
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
        input::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    _use_stock_state_update() && return _stock_state_update!(container, model, key, input)
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
        input::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    _use_stock_state_update() && return _stock_state_update!(container, model, key, input)
    minutes = Dates.value(Millisecond(PSI.get_resolution(model))) / 60000
    _update_state_parameters!(container, model, key) do device, stamp
        return _mnsp_ramp_rate_at(device, false, stamp, minutes)
    end
    return
end
