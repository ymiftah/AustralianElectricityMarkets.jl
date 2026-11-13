# The replay input stage: each family's writer is called from `_set_replay_inputs!` in a fixed order.
include("replay_inputs/common.jl")
include("replay_inputs/energy_offers.jl")


"""
    _set_replay_inputs!(sys::PSY.System) -> Nothing

Writes the replay input series derived from the built inputs of `sys`, in a fixed order. The first
writer adds the energy offer curves of each bidding device, one series per offer side, with the band
prices referred to the reference node by the side's loss factor. Called by [`nem_system`](@ref) before
its input checks.

# Arguments
- `sys`: the system built by [`nem_system`](@ref).

# Returns
`nothing`.
"""
function _set_replay_inputs!(sys::PSY.System)
    _set_referred_energy_offers!(sys)
    return
end
