# TODO no need for a module with a single helper. there shouuld be a better place for this.


"""
    nem_dispatch_devices(sys) -> Vector{Device}

Collects every available device in `sys` whose type is in [`NEM_DISPATCH_DEVICE_TYPES`](@ref) and
that carries a [`NEMUnitData`](@ref), the replay units that the dispatch limits apply to.

# Arguments
- `sys`: the `System` to collect from.

# Returns
A `Vector{Device}`.
"""
function nem_dispatch_devices(sys)
    devices = Device[]
    for T in NEM_DISPATCH_DEVICE_TYPES
        append!(devices, filter(has_nem_unit_data, collect(get_components(get_available, T, sys))))
    end
    return devices
end
