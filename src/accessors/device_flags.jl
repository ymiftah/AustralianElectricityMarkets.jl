"""
    is_non_scheduled_load(device) -> Bool

Whether `device` is a non-scheduled load: it has no energy bid, and takes part in the market only
through FCAS offers. A NEM build records this on the load's [`NEMRegistration`](@ref);
`ext["non_scheduled"]`, written by a stock build, is honoured as an override.

# Arguments
- `device`: any component.

# Returns
`Bool`.
"""
function is_non_scheduled_load(device)
    device isa ControllableLoad || return false
    get(get_ext(device), "non_scheduled", nothing) === true && return true
    return has_registration(device) && device.registration.schedule_type == ScheduleType.NON_SCHEDULED
end


"""
    is_commissioned(device) -> Bool

Whether `device` is commissioned. A NEM build records it on the device's
[`NEMRegistration`](@ref); `ext["commissioned"]`, written by a stock build, is honoured as an
override. Any other device is commissioned.

# Returns
`Bool`.
"""
function is_commissioned(device)
    flag = get(get_ext(device), "commissioned", nothing)
    isnothing(flag) || return flag === true
    return has_registration(device) ? device.registration.commissioned : true
end


"""
    has_registration(device) -> Bool

Whether `device` carries a [`NEMRegistration`](@ref), which holds its schedule type.

# Returns
`Bool`.
"""
has_registration(device) = device isa Union{NEM_DISPATCH_DEVICE_TYPES...} && !isnothing(device.registration)


"""
    is_semi_scheduled(device) -> Bool

Whether `device` is semi-scheduled, from the schedule type of its [`NEMRegistration`](@ref). Throws an
`ArgumentError` naming `device` when it has no registration.

# Returns
`Bool`.
"""
function is_semi_scheduled(device)
    return get_registration(device).schedule_type == ScheduleType.SEMI_SCHEDULED
end


"""
    energy_offer_sides(device) -> Tuple{Vararg{OfferSide}}

The sides a scheduled `device` offers energy on: `GEN` for a generating unit, `LOAD` for a
controllable load, both for a storage device.

# Returns
A tuple of [`OfferSide`](@ref)s.
"""
energy_offer_sides(::PSY.Device) = (OfferSide.GEN,)
energy_offer_sides(::PSY.ControllableLoad) = (OfferSide.LOAD,)
energy_offer_sides(::PSY.Storage) = (OfferSide.GEN, OfferSide.LOAD)
