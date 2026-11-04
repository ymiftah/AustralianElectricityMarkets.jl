import AustralianElectricityMarkets as AEM
using Dates: DateTime, Minute
const _IS = PowerSystems.IS

function _offer_key(name::String)
    return _IS.StaticTimeSeriesKey(;
        time_series_type = PowerSystems.SingleTimeSeries, name,
        initial_timestamp = DateTime(2025, 1, 1), resolution = Minute(5), length = 12,
        features = Dict{String, Any}(),
    )
end

_energy_bid(side) = NEMEnergyBid(side, _offer_key("c$(side)"), _offer_key("m$(side)"))
_fcas_bid(service, side) = NEMFCASBid(service, side, _offer_key("c$(service)$(side)"), _offer_key("t$(service)$(side)"))

@testset "NEMOfferCost replaces bids of the same side" begin
    cost = NEMOfferCost()
    @test isempty(get_energy_bids(cost)) && isempty(get_fcas_bids(cost))
    @test get_fixed_load(cost) === nothing && get_fixed_load_invoked(cost) === nothing

    AEM._set_energy_bid!(cost, _energy_bid(OfferSide.GEN))
    AEM._set_energy_bid!(cost, _energy_bid(OfferSide.GEN))
    @test length(get_energy_bids(cost)) == 1
    AEM._set_energy_bid!(cost, _energy_bid(OfferSide.LOAD))
    @test length(get_energy_bids(cost)) == 2

    AEM._set_fcas_bid!(cost, _fcas_bid(BidType.RAISE6SEC, OfferSide.GEN))
    AEM._set_fcas_bid!(cost, _fcas_bid(BidType.RAISE6SEC, OfferSide.GEN))
    @test length(get_fcas_bids(cost)) == 1
    AEM._set_fcas_bid!(cost, _fcas_bid(BidType.RAISE6SEC, OfferSide.LOAD))
    AEM._set_fcas_bid!(cost, _fcas_bid(BidType.LOWER6SEC, OfferSide.GEN))
    @test length(get_fcas_bids(cost)) == 3
end

@testset "NEMOfferCost serializes" begin
    cost = NEMOfferCost(;
        energy = [_energy_bid(OfferSide.GEN)],
        fcas = [_fcas_bid(BidType.RAISE6SEC, OfferSide.LOAD)],
        fixed_load = _offer_key("fixed_load"),
        fixed_load_invoked = _offer_key("fixed_load_invoked"),
    )
    @test _IS.deserialize(NEMOfferCost, _IS.serialize(cost)) == cost
    empty = NEMOfferCost()
    @test _IS.deserialize(NEMOfferCost, _IS.serialize(empty)) == empty
end
