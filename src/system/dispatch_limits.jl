"""
    nem_dispatch_devices(sys) -> Vector{Device}

Collects every available device whose type is in [`NEM_DISPATCH_DEVICE_TYPES`](@ref) in `sys`, the
device types that the dispatch limits applies to.

# Arguments
- `sys`: the `System` to collect from.

# Returns
A `Vector{Device}`.
"""
function nem_dispatch_devices(sys)
    devices = Device[]
    for T in NEM_DISPATCH_DEVICE_TYPES
        append!(devices, collect(get_components(get_available, T, sys)))
    end
    return devices
end
