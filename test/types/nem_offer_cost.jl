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

_curves() = PowerSystems.PiecewiseStepData([0.0, 10.0, 20.0], [5.0, 50.0])

# An energy bid with every optional field set to a static value.
function _static_energy_bid(direction)
    return AEM.NEMEnergyBid(;
        direction, offer_curves = _curves(), max_avail = 100.0, roc_up = 1.5, roc_down = 2.5,
        fixed_load = 3.0, minimum_load = 4.0, fast_start_profile = (t1 = 1.0, t2 = 2.0, t3 = 3.0, t4 = 4.0),
        daily_energy_constraint = 500.0, normal_status = true, energy_limit = 60.0,
    )
end

# An energy bid with every field held as a time series, and the optional ones unset.
function _keyed_energy_bid(direction)
    return AEM.NEMEnergyBid(;
        direction, offer_curves = _offer_key("curves_$direction"), max_avail = _offer_key("max_$direction"),
        roc_up = _offer_key("up_$direction"), roc_down = _offer_key("down_$direction"),
        fixed_load = _offer_key("fixed_$direction"), minimum_load = nothing,
        fast_start_profile = _offer_key("t_$direction"), daily_energy_constraint = nothing,
        normal_status = _offer_key("status_$direction"), energy_limit = nothing,
    )
end

_static_fcas_bid(service, direction) = AEM.NEMFCASBid(;
    service, direction, offer_curves = _curves(), max_avail = 10.0,
    trapezium = (enablement_min = 0.0, low_breakpoint = 1.0, high_breakpoint = 2.0, enablement_max = 3.0),
)

_keyed_fcas_bid(service, direction) = AEM.NEMFCASBid(;
    service, direction, offer_curves = _offer_key("c_$(service)_$direction"),
    max_avail = _offer_key("m_$(service)_$direction"), trapezium = _offer_key("t_$(service)_$direction"),
)

@testset "NEMOfferCost replaces bids of the same direction" begin
    cost = NEMOfferCost()
    @test isempty(get_energy_bids(cost)) && isempty(get_fcas_bids(cost))

    AEM._set_energy_bid!(cost, _static_energy_bid(AEM.BidDirection.GEN))
    AEM._set_energy_bid!(cost, _static_energy_bid(AEM.BidDirection.GEN))
    @test length(get_energy_bids(cost)) == 1
    AEM._set_energy_bid!(cost, _static_energy_bid(AEM.BidDirection.LOAD))
    @test length(get_energy_bids(cost)) == 2

    AEM._set_fcas_bid!(cost, _static_fcas_bid(BidType.RAISE6SEC, AEM.BidDirection.GEN))
    AEM._set_fcas_bid!(cost, _static_fcas_bid(BidType.RAISE6SEC, AEM.BidDirection.GEN))
    @test length(get_fcas_bids(cost)) == 1
    AEM._set_fcas_bid!(cost, _static_fcas_bid(BidType.RAISE6SEC, AEM.BidDirection.LOAD))
    AEM._set_fcas_bid!(cost, _static_fcas_bid(BidType.LOWER6SEC, AEM.BidDirection.BIDIRECTIONAL))
    @test length(get_fcas_bids(cost)) == 3
end

@testset "bid types construct statically and compare by value" begin
    bid = _static_energy_bid(AEM.BidDirection.GEN)
    @test bid == _static_energy_bid(AEM.BidDirection.GEN)
    @test bid != _static_energy_bid(AEM.BidDirection.LOAD)
    @test AEM.get_fast_start_profile(bid) == AEM.FastStartProfile((1.0, 2.0, 3.0, 4.0))
    @test AEM.get_normal_status(bid) === true
    @test isnothing(AEM.get_energy_limit(_keyed_energy_bid(AEM.BidDirection.GEN)))

    fcas = _static_fcas_bid(BidType.RAISE6SEC, AEM.BidDirection.GEN)
    @test AEM.get_trapezium(fcas) == AEM.FCASTrapeziumPoints((0.0, 1.0, 2.0, 3.0))
    @test AEM.get_service(fcas) == BidType.RAISE6SEC
    @test fcas == _static_fcas_bid(BidType.RAISE6SEC, AEM.BidDirection.GEN)
end

@testset "bid series are named by service, field and direction" begin
    @test AEM.bid_series_name(BidType.ENERGY, :offer_curves, AEM.BidDirection.GEN) == "bid_energy_offer_curves_gen"
    @test AEM.bid_series_name(BidType.RAISE6SEC, :trapezium, AEM.BidDirection.BIDIRECTIONAL) ==
        "bid_raise6sec_trapezium_bidirectional"
end

@testset "bid_value returns the static value, or the window in the static type" begin
    @test AEM.bid_value(nothing, _static_energy_bid(AEM.BidDirection.GEN), :max_avail, DateTime(2025), 3) == 100.0
    @test isnothing(AEM.bid_value(nothing, _keyed_energy_bid(AEM.BidDirection.GEN), :energy_limit, DateTime(2025), 3))
end

@testset "NEMEnergyBid JSON round trip keeps its key fields" begin
    bid = _keyed_energy_bid(AEM.BidDirection.GEN)
    restored = _IS.deserialize(AEM.NEMEnergyBid, _IS.serialize(bid))
    @test restored == bid
    @test restored.max_avail isa _IS.StaticTimeSeriesKey
    @test isnothing(restored.energy_limit)
end

@testset "NEMOfferCost serializes static and key-backed bids" begin
    cost = NEMOfferCost(;
        energy = [_static_energy_bid(AEM.BidDirection.GEN), _keyed_energy_bid(AEM.BidDirection.LOAD)],
        fcas = [_static_fcas_bid(BidType.RAISE6SEC, AEM.BidDirection.LOAD), _keyed_fcas_bid(BidType.LOWER6SEC, AEM.BidDirection.GEN)],
    )
    restored = _IS.deserialize(NEMOfferCost, _IS.serialize(cost))
    @test restored == cost
    @test AEM.get_fast_start_profile(get_energy_bids(restored)[1]) == AEM.FastStartProfile((1.0, 2.0, 3.0, 4.0))
    @test AEM.get_trapezium(get_fcas_bids(restored)[1]) == AEM.FCASTrapeziumPoints((0.0, 1.0, 2.0, 3.0))

    empty = NEMOfferCost()
    @test _IS.deserialize(NEMOfferCost, _IS.serialize(empty)) == empty
end

@testset "NEMEnergyBid band_prices default to nothing, compare by value and round-trip as a ten-tuple" begin
    prices = (5.0, 50.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    bid = _static_energy_bid(AEM.BidDirection.GEN)
    @test isnothing(bid.band_prices)
    priced = AEM.NEMEnergyBid(;
        direction = AEM.BidDirection.GEN, offer_curves = _curves(), max_avail = 100.0, roc_up = 1.5, roc_down = 2.5,
        fixed_load = 3.0, minimum_load = 4.0, fast_start_profile = (t1 = 1.0, t2 = 2.0, t3 = 3.0, t4 = 4.0),
        daily_energy_constraint = 500.0, normal_status = true, energy_limit = 60.0, band_prices = prices,
    )
    @test priced != bid
    @test hash(priced) != hash(bid)
    restored = _IS.deserialize(AEM.NEMEnergyBid, _IS.serialize(priced))
    @test restored == priced
    @test restored.band_prices isa NTuple{10, Float64}
    @test restored.band_prices == prices
end

@testset "NEMFCASBid band_prices default to nothing, compare by value and round-trip as a ten-tuple" begin
    prices = (5.0, 12.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    bid = _static_fcas_bid(BidType.RAISE6SEC, AEM.BidDirection.GEN)
    @test isnothing(bid.band_prices)
    priced = AEM.NEMFCASBid(;
        service = BidType.RAISE6SEC, direction = AEM.BidDirection.GEN, offer_curves = _curves(), max_avail = 10.0,
        trapezium = (enablement_min = 0.0, low_breakpoint = 1.0, high_breakpoint = 2.0, enablement_max = 3.0),
        band_prices = prices,
    )
    @test priced != bid
    @test hash(priced) != hash(bid)
    restored = _IS.deserialize(AEM.NEMFCASBid, _IS.serialize(priced))
    @test restored == priced
    @test restored.band_prices isa NTuple{10, Float64}
    @test restored.band_prices == prices
end
