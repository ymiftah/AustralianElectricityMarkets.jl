# Throws when two FCAS bids of one service map to the same side of a unit: only the first is read.
function _check_fcas_bid_sides(sys::PSY.System)
    for device in _bidding_devices(sys)
        cost = _nem_offer_cost(device)
        isnothing(cost) && continue
        seen = Set{Tuple{BidType, OfferSide}}()
        for bid in get_fcas_bids(cost)
            side = _fcas_bid_side(device, bid)
            isnothing(side) && continue
            (bid.service, side) in seen && throw(
                ArgumentError("\"$(PSY.get_name(device))\" has two $(bid.service) bids on the $(side) side; only the first is read."),
            )
            push!(seen, (bid.service, side))
        end
    end
    return
end


"""
    _set_referred_energy_offers!(sys::PSY.System) -> Nothing

Adds the energy offer curves of each bidding device of `sys`, one series per offer side named by
[`energy_offer_series_name`](@ref). The band prices are the bid's curve prices referred to the reference
node by the side's loss factor and rounded to cents. Throws `ArgumentError` when two FCAS bids of one
service map to the same side of a unit, or when an energy bid is static rather than series-backed.

# Arguments
- `sys`: the system whose bids [`nem_system`](@ref) attached.

# Returns
`nothing`.
"""
function _set_referred_energy_offers!(sys::PSY.System)
    _check_fcas_bid_sides(sys)
    for device in _bidding_devices(sys)
        cost = _nem_offer_cost(device)
        isnothing(cost) && continue
        for side in energy_offer_sides(device)
            bid = _energy_bid(cost, side)
            isnothing(bid) && continue
            curves = _bid_series(device, bid.offer_curves, :offer_curves)
            factor = Float64(_loss_factor(device, side))
            referred = [
                PSY.PiecewiseStepData(PSY.get_x_coords(c), referred_price.(PSY.get_y_coords(c), factor)) for c in curves.values
            ]
            PSY.add_time_series!(
                sys, device,
                single_series(energy_offer_series_name(side), first(curves.timestamps), referred, curves.resolution),
            )
        end
    end
    return
end
