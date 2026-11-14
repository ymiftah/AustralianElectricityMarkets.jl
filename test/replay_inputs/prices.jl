# The band prices of each energy bid, written on the mock replay System (AEMSim not loaded).

# A NEM replay System on the mock hive, with its replay inputs written by `nem_system`.
function _prices_mock_system()
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    t = DateTime(2025, 1, 1, 0, 5)
    return nem_system(db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(20)))
end

_prices_curve(prices) = PowerSystems.PiecewiseStepData(collect(0.0:10.0:(10.0 * length(prices))), prices)

@testset "_day_band_prices pads to ten, ignores stamps outside the replay range and throws on variation" begin
    AEM = AustralianElectricityMarkets
    curves = [_prices_curve([5.0, 50.0]), _prices_curve([5.0, 50.0]), _prices_curve([7.0, 50.0, 90.0])]
    @test AEM._day_band_prices(curves, [true, true, false], "X") == (5.0, 50.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    @test_throws r"band prices of X vary within the replay range; a NEMDE system covers one trading day" AEM._day_band_prices(
        curves, [true, true, true], "X",
    )
    @test_throws r"X has no offer curve in the replay range" AEM._day_band_prices(curves, [false, false, false], "X")
    wide = [_prices_curve(collect(1.0:11.0))]
    @test_throws r"11 bands" AEM._day_band_prices(wide, [true], "X")
end

@testset "bids of a built system carry the referred prices of their energy offer series" begin
    AEM = AustralianElectricityMarkets
    sys = _prices_mock_system()
    checked = Dict(AEM.OfferSide.GEN => 0, AEM.OfferSide.LOAD => 0)
    for device in AEM._bidding_devices(sys)
        cost = AEM._nem_offer_cost(device)
        isnothing(cost) && continue
        for side in AEM.energy_offer_sides(device)
            bid = AEM._energy_bid(cost, side)
            isnothing(bid) && continue
            direction = side == AEM.OfferSide.LOAD ? AEM.BidDirection.LOAD : AEM.BidDirection.GEN
            raw = PowerSystems.get_time_series_values(
                PowerSystems.SingleTimeSeries, device, AEM.bid_series_name(AEM.BidType.ENERGY, :offer_curves, direction);
                ignore_scaling_factors = true,
            )
            registration = AEM.get_registration(device)
            factor = side == AEM.OfferSide.LOAD ? registration.load_loss_factor : registration.gen_loss_factor
            y = PowerSystems.get_y_coords(first(raw))
            expected = ntuple(i -> i <= length(y) ? AEM.referred_price(y[i], factor) : 0.0, 10)
            @test bid.band_prices == expected
            checked[side] += 1
        end
    end
    @test checked[AEM.OfferSide.GEN] > 0
    @test checked[AEM.OfferSide.LOAD] > 0
end

# Replaces the first energy offer series of `sys` on its GEN side with `curves` and returns the device.
function _prices_replace_offer!(sys, curves)
    AEM = AustralianElectricityMarkets
    device = first(d for d in AEM._bidding_devices(sys) if PowerSystems.has_time_series(d, PowerSystems.SingleTimeSeries, AEM.energy_offer_series_name(AEM.OfferSide.GEN)))
    name = AEM.energy_offer_series_name(AEM.OfferSide.GEN)
    stamps = PowerSystems.get_time_series_timestamps(PowerSystems.SingleTimeSeries, device, name)
    remove_series_and_forecast!(sys, device, name)
    PowerSystems.add_time_series!(sys, device, AEM.single_series(name, first(stamps), curves(stamps), Minute(5)))
    return device
end

@testset "a price change inside the replay range throws; one in the trailing stamps does not" begin
    AEM = AustralianElectricityMarkets
    sys = _prices_mock_system()
    stamps = AEM._replay_interval_stamps(sys)
    flat = _prices_curve([20.0, 40.0])
    moved = _prices_curve([21.0, 40.0])
    replay = Set(stamps)
    @test length(stamps) >= 2
    _prices_replace_offer!(sys, ts -> [t in replay ? flat : moved for t in ts])
    @test isnothing(AEM._set_band_prices!(sys))
    second = stamps[2]
    _prices_replace_offer!(sys, ts -> [t < second ? flat : moved for t in ts])
    @test_throws r"vary within the replay range" AEM._set_band_prices!(sys)
end

# The FCAS bids of `sys` with a modelled side and an `offer_curves` series, as `(device, bid)`.
function _prices_fcas_bids(sys)
    AEM = AustralianElectricityMarkets
    found = Tuple{Any, Any}[]
    for device in AEM._bidding_devices(sys)
        cost = AEM._nem_offer_cost(device)
        isnothing(cost) && continue
        for bid in AEM.get_fcas_bids(cost)
            isnothing(AEM._fcas_bid_side(device, bid)) && continue
            push!(found, (device, bid))
        end
    end
    return found
end

@testset "FCAS bids of a built system carry the unreferred prices of the first replay interval" begin
    AEM = AustralianElectricityMarkets
    sys = _prices_mock_system()
    checked = Dict(AEM.OfferSide.GEN => 0, AEM.OfferSide.LOAD => 0)
    for (device, bid) in _prices_fcas_bids(sys)
        raw = PowerSystems.get_time_series_values(
            PowerSystems.SingleTimeSeries, device, AEM.IS.get_name(bid.offer_curves); ignore_scaling_factors = true,
        )
        y = PowerSystems.get_y_coords(first(raw))
        @test bid.band_prices == ntuple(i -> i <= length(y) ? Float64(y[i]) : 0.0, 10)
        checked[AEM._fcas_bid_side(device, bid)] += 1
    end
    @test checked[AEM.OfferSide.GEN] > 0
    @test checked[AEM.OfferSide.LOAD] > 0
end

@testset "an FCAS price change inside the replay range throws naming the unit and service" begin
    AEM = AustralianElectricityMarkets
    sys = _prices_mock_system()
    stamps = AEM._replay_interval_stamps(sys)
    @test length(stamps) >= 2
    device, bid = first(_prices_fcas_bids(sys))
    name = AEM.IS.get_name(bid.offer_curves)
    all_stamps = PowerSystems.get_time_series_timestamps(PowerSystems.SingleTimeSeries, device, name)
    flat = _prices_curve([20.0, 40.0])
    moved = _prices_curve([21.0, 40.0])
    second = stamps[2]
    remove_series_and_forecast!(sys, device, name)
    PowerSystems.add_time_series!(
        sys, device, AEM.single_series(name, first(all_stamps), [t < second ? flat : moved for t in all_stamps], Minute(5)),
    )
    @test_throws Regex("band prices of $(PowerSystems.get_name(device)) $(bid.service) .* vary within the replay range") AEM._set_band_prices!(sys)
end

@testset "an FCAS bid with a static offer_curves field throws, naming the unit" begin
    AEM = AustralianElectricityMarkets
    sys = _prices_mock_system()
    device, bid = first(_prices_fcas_bids(sys))
    static = AEM.NEMFCASBid(;
        service = bid.service, direction = bid.direction, offer_curves = _prices_curve([20.0, 40.0]),
        max_avail = bid.max_avail, trapezium = bid.trapezium,
    )
    AEM._set_fcas_bid!(AEM._nem_offer_cost(device), static)
    @test_throws Regex("\\\"$(PowerSystems.get_name(device))\\\" has a static `offer_curves` field") AEM._set_band_prices!(sys)
end

# The MNSP interchanges of `sys` as `(device, bid)`.
function _prices_mnsp_bids(sys)
    AEM = AustralianElectricityMarkets
    found = Tuple{Any, Any}[]
    for device in PowerSystems.get_components(PowerSystems.AreaInterchange, sys), bid in PowerSystems.get_supplemental_attributes(AEM.NEMMNSPBid, device)
        push!(found, (device, bid))
    end
    return found
end

@testset "MNSP bids of a built system carry the first replay interval's prices, band k at PRICEBAND<k>" begin
    AEM = AustralianElectricityMarkets
    sys = _prices_mock_system()
    bids = _prices_mnsp_bids(sys)
    @test !isempty(bids)
    for (device, bid) in bids
        raw = PowerSystems.get_time_series_values(
            PowerSystems.SingleTimeSeries, device, AEM.IS.get_name(bid.offer_curves); ignore_scaling_factors = true,
        )
        y = PowerSystems.get_y_coords(first(raw))
        @test length(y) == 10
        @test bid.band_prices == ntuple(i -> Float64(y[i]), 10)
    end
    @test Set(b.direction for (_, b) in bids) == Set([AEM.MNSPDirection.FORWARD, AEM.MNSPDirection.REVERSE])
end

@testset "an MNSP price change inside the replay range throws naming the interchange" begin
    AEM = AustralianElectricityMarkets
    sys = _prices_mock_system()
    stamps = AEM._replay_interval_stamps(sys)
    @test length(stamps) >= 2
    device, bid = first(_prices_mnsp_bids(sys))
    name = AEM.IS.get_name(bid.offer_curves)
    all_stamps = PowerSystems.get_time_series_timestamps(PowerSystems.SingleTimeSeries, device, name)
    flat = _prices_curve(fill(20.0, 10))
    moved = _prices_curve(fill(21.0, 10))
    second = stamps[2]
    remove_series_and_forecast!(sys, device, name)
    PowerSystems.add_time_series!(
        sys, device, AEM.single_series(name, first(all_stamps), [t < second ? flat : moved for t in all_stamps], Minute(5)),
    )
    @test_throws Regex("band prices of $(PowerSystems.get_name(device)) MNSP .* vary within the replay range") AEM._set_band_prices!(sys)
end
