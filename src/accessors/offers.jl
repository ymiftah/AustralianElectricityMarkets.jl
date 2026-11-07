const _NEMDevice = Union{NEM_DISPATCH_DEVICE_TYPES...}

"""
    energy_max_avail_series_name(device, side::OfferSide) -> String

Name of the series holding `device`'s energy offer `MAXAVAIL` for `side`, as the dispatch formulation
reads it: per side for a `Storage` device, and `energy_max_avail` for any other device (a scheduled
load's `LOAD` offer included).
"""
function energy_max_avail_series_name(device, side::OfferSide)
    return energy_max_avail_series_name(device isa PSY.Storage ? side : OfferSide.GEN)
end

# `device`'s `NEMOfferCost`, or `nothing` for a device that is not a NEM type.
_nem_offer_cost(::Any) = nothing
_nem_offer_cost(device::_NEMDevice) = get_operation_cost(device)
