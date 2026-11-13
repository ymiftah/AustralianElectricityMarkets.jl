# The replay input stage: each family's writer is called from `_set_replay_inputs!` in a fixed order.
include("replay_inputs/common.jl")
include("replay_inputs/energy_offers.jl")
include("replay_inputs/mnsp_fixed_loads.jl")
include("replay_inputs/dispatch_limits.jl")
include("replay_inputs/state_inputs.jl")


"""
    _set_replay_inputs!(sys::PSY.System) -> Nothing

Writes the replay input series derived from the built inputs of `sys`, in a fixed order. The first
writer adds the energy offer curves of each bidding device, one series per offer side, with the band
prices referred to the reference node by the side's loss factor. The second adds the fixed-loading
value and invocation series of each MNSP link direction, named by [`NEM_MNSP_FIXED_LOAD_SERIES`](@ref).
The third adds the dispatch ramp rates of each replay unit, named by [`NEM_SERIES`](@ref), and its AGC ramp
rates, named by `fcas_series_name("fcas_agc_ramp_rate", service)`. The fourth adds the observed starting output
of each replay unit and its fixed-loading target and invocation, named by [`NEM_STATE_INPUT_SERIES`](@ref).
Called by [`nem_system`](@ref) before its input checks.

# Arguments
- `sys`: the system built by [`nem_system`](@ref).

# Returns
`nothing`.
"""
function _set_replay_inputs!(sys::PSY.System)
    _set_referred_energy_offers!(sys)
    _set_mnsp_fixed_loads!(sys)
    _set_dispatch_limits!(sys)
    _set_observed_state_inputs!(sys)
    return
end
