# `device`'s `NEMOfferCost`, or `nothing` for a device without NEM unit data.
_nem_offer_cost(::Any) = nothing

# A stock device's offer lives in its `NEMUnitData`.
function _nem_offer_cost(device::PSY.Component)
    unit = _nem_unit_data(device)
    return isnothing(unit) ? nothing : unit.offer
end
