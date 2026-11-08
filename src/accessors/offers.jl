const _NEMDevice = Union{NEM_DISPATCH_DEVICE_TYPES...}

# `device`'s `NEMOfferCost`, or `nothing` for a device that is not a NEM type.
_nem_offer_cost(::Any) = nothing
_nem_offer_cost(device::_NEMDevice) = get_operation_cost(device)
