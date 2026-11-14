"""
    _max_avail_series_name(side::OfferSide) -> String

Name of the energy bid `MAXAVAIL` series on `side`, the series the dispatch parameters register for
their availability (MW).

# Arguments
- `side`: the [`OfferSide`](@ref) of the energy bid.

# Returns
A `String`.
"""
function _max_avail_series_name(side::OfferSide)
    direction = side == OfferSide.LOAD ? AustralianElectricityMarkets.BidDirection.LOAD : AustralianElectricityMarkets.BidDirection.GEN
    return AustralianElectricityMarkets.bid_series_name(BidType.ENERGY, :max_avail, direction)
end
