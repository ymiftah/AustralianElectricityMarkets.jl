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

Refreshes [`MNSPOperatingParameter`](@ref) from each link's metered flow and bid ramp rates at the step,
read through the configured [`StateSource`](@ref). The key's meta selects the input:
the metered flow in MW (the starting point of the [`mnsp_ramp_envelope`](@ref) the formulation builds each
ramp row from), or the forward or reverse rate of that envelope in MW/min. The fixed-loading inputs
take the stock update.
Under [`ObservedState`](@ref) the stock PowerSimulations update refreshes it from the series that
[`prepare_replay!`](@ref) attached. Under [`SimulatedState`](@ref), or when the custom path is forced,
it is recomputed from each device's [`NEMUnitState`](@ref) at the step.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the link's type.
- `input`: the simulation state, passed to the stock update and not read by the custom one.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{MNSPOperatingParameter, PSY.AreaInterchange},
        input::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    _use_stock_state_update() && return _stock_state_update!(container, model, key, input)
    _update_mnsp_input!(_mnsp_input_kind(key.meta), container, model, key, input)
    return
end

function _update_mnsp_input!(::MNSPInitialFlowInput, container, model, key, input)
    _update_state_parameters!(container, model, key) do device, stamp
        return _mnsp_initial_flow(_state_source(), device, stamp)
    end
    return
end

function _update_mnsp_input!(::MNSPRampRateInput, container, model, key, input)
    minutes = Dates.value(Millisecond(PSI.get_resolution(model))) / 60000
    forward = _mnsp_input_link(key.meta) isa MNSPForwardLink
    _update_state_parameters!(container, model, key) do device, stamp
        return _mnsp_ramp_rate_at(device, forward, stamp, minutes)
    end
    return
end

# The fixed-loading inputs have no custom update.
function _update_mnsp_input!(::Union{MNSPFixedLoadInput, MNSPFixedLoadInvokedInput}, container, model, key, input)
    return _stock_state_update!(container, model, key, input)
end
