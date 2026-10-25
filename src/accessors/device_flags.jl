"""
    is_non_scheduled_load(device) -> Bool

Whether `device` is a non-scheduled load ([`get_scheduled_loads_dataframe`](@ref)): it has no
energy bid, and takes part in the market only through FCAS offers.

# Arguments
- `device`: any component.

# Returns
`Bool`.
"""
is_non_scheduled_load(device) = device isa InterruptiblePowerLoad && get(get_ext(device), "non_scheduled", false) === true


"""
    is_commissioned(device) -> Bool

Whether `device` is commissioned. Only a non-scheduled load records the flag; any other device is
commissioned.

# Returns
`Bool`.
"""
is_commissioned(device) = get(get_ext(device), "commissioned", true) === true


"""
    has_schedule_classification(device) -> Bool

Whether [`set_nem_energy_limits!`](@ref) has classified `device` as scheduled or semi-scheduled.

# Returns
`Bool`.
"""
has_schedule_classification(device) = get(get_ext(device), "nem_semi_scheduled", nothing) isa Bool


"""
    is_semi_scheduled(device) -> Bool

Whether `device` is semi-scheduled, as classified by [`set_nem_energy_limits!`](@ref). Throws an
`ArgumentError` when `device` has no classification.

# Returns
`Bool`.
"""
function is_semi_scheduled(device)
    has_schedule_classification(device) || throw(
        ArgumentError("$(get_name(device)): missing schedule classification; call set_nem_energy_limits!"),
    )
    return get_ext(device)["nem_semi_scheduled"]
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
