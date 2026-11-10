const _NEMDevice = Union{NEM_DISPATCH_DEVICE_TYPES...}

# `device`'s `NEMOfferCost`, or `nothing` for a device that is not a NEM type.
_nem_offer_cost(::Any) = nothing
_nem_offer_cost(device::_NEMDevice) = get_operation_cost(device)

# A stock device's offer lives in its `NEMUnitData`.
function _nem_offer_cost(device::PSY.Component)
    unit = _nem_unit_data(device)
    return isnothing(unit) ? nothing : unit.offer
end
