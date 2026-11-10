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

# Calls `f` on each available device of type `T` in `sys` that carries NEM unit data, in order.
function _foreach_nem_dispatch_device_of(f::F, ::Type{T}, sys::PSY.System) where {F, T}
    for device in get_components(get_available, T, sys)
        has_nem_unit_data(device) && f(device)
    end
    return
end

# Calls `f` on each device `nem_dispatch_devices` collects, in the same order, without collecting them.
function _foreach_nem_dispatch_device(f::F, sys::PSY.System) where {F}
    foreach(T -> _foreach_nem_dispatch_device_of(f, T, sys), NEM_DISPATCH_DEVICE_TYPES)
    return
end
