"""
    is_non_scheduled_load(device) -> Bool

Whether `device` is a non-scheduled load (`get_scheduled_loads_dataframe`): it has no
energy bid, and takes part in the market only through FCAS offers.

# Arguments
- `device`: any component.

# Returns
`Bool`.
"""
is_non_scheduled_load(device) = device isa ControllableLoad && get(get_ext(device), "non_scheduled", false) === true


"""
    is_commissioned(device) -> Bool

Whether `device` is commissioned. Only a non-scheduled load records the flag; any other device is
commissioned.

# Returns
`Bool`.
"""
is_commissioned(device) = get(get_ext(device), "commissioned", true) === true


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
