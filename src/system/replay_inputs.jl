# The replay input stage: each family's writer is called from `_set_replay_inputs!` in a fixed order.
include("replay_inputs/common.jl")


"""
    _set_replay_inputs!(sys::PSY.System) -> Nothing

Writes the replay inputs derived from the built inputs of `sys`, in the order of the replay stages.
Called by [`nem_system`](@ref) before its input checks; it writes nothing yet.

# Arguments
- `sys`: the system built by [`nem_system`](@ref).

# Returns
`nothing`.
"""
function _set_replay_inputs!(sys::PSY.System)
    return
end
