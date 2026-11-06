@testset "Market bids" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates
    using DataFrames
    AEM = AustralianElectricityMarkets

    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    grid = collect(interval)[1:(end - 1)]
    series(device, name) = get_time_series_values(SingleTimeSeries, device, name; ignore_scaling_factors = true)
    energy_bid(device, direction) = only(b for b in AEM.get_energy_bids(get_operation_cost(device)) if b.direction == direction)

    @testset "bid series equal the read_offers columns, on the grid" begin
        sys, _ = nem_network(db; as_of = first(interval), through = last(interval) - Minute(5))
        offers = read_offers(db, interval)
        set_market_bids!(sys, db, interval)
        for (duid, direction) in (("BW01", AEM.BidDirection.GEN), ("BW01", AEM.BidDirection.LOAD), ("BW02", AEM.BidDirection.GEN), ("BW04", AEM.BidDirection.GEN), ("PUMP1", AEM.BidDirection.LOAD), ("ER01", AEM.BidDirection.GEN))
            device = get_component(PowerSystems.Device, sys, duid)
            keep = (offers.DUID .== duid) .& (offers.DIRECTION .== string(direction)) .& (offers.BIDTYPE .== Ref(BidType.ENERGY))
            rows = sort(offers[keep, :], :INTERVAL_DATETIME)
            @test rows.INTERVAL_DATETIME == grid
            @test series(device, AEM.bid_series_name(BidType.ENERGY, :max_avail, direction)) == rows.MAXAVAIL
            @test series(device, AEM.bid_series_name(BidType.ENERGY, :roc_up, direction)) == coalesce.(rows.ROCUP, 0.0)
        end
    end

    @testset "NULL fields are nothing when NULL throughout, and zero where NULL on some intervals" begin
        sys, _ = nem_network(db; as_of = first(interval), through = last(interval) - Minute(5))
        set_market_bids!(sys, db, interval)
        er01 = energy_bid(get_component(NEMThermalGen, sys, "ER01"), AEM.BidDirection.GEN)
        @test isnothing(er01.energy_limit)
        @test isnothing(er01.fixed_load)
        # BW02 carries a 50 MW fixed load at 00:10 and 00:15 only.
        @test series(get_component(Device, sys, "BW02"), AEM.bid_series_name(BidType.ENERGY, :fixed_load, AEM.BidDirection.GEN)) == [0.0, 50.0, 50.0]
    end

    @testset "fast-start profile is stored as a NTuple and read back as a FastStartProfile" begin
        sys, _ = nem_network(db; as_of = first(interval), through = last(interval) - Minute(5), time_series_in_memory = false)
        set_market_bids!(sys, db, interval)
        bw04 = get_component(Device, sys, "BW04")
        bid = energy_bid(bw04, AEM.BidDirection.GEN)
        profile = AEM.bid_value(bw04, bid, :fast_start_profile, first(interval), 3)
        @test profile isa Vector{AEM.FastStartProfile}
        @test all(p -> p.t1 == 10.0, profile)
    end

    @testset "markets restrict the bids, series and services read" begin
        sys, _ = nem_network(db; as_of = first(interval), through = last(interval) - Minute(5))
        res = set_market_bids!(sys, db, interval; markets = (BidType.ENERGY, BidType.RAISE6SEC))
        lower = AEM.bid_series_name(BidType.LOWER6SEC, :offer_curves, AEM.BidDirection.GEN)
        @test !any(d -> has_time_series(d, SingleTimeSeries, lower), get_components(Device, sys))
        @test !any(s -> get_bid_type(s) == BidType.LOWER6SEC, get_components(FCASService, sys))
        @test isempty(filter(n -> endswith(n, "LOWER6SEC"), res.added))
        @test any(s -> get_bid_type(s) == BidType.RAISE6SEC, get_components(FCASService, sys))
    end

    @testset "a registered unit without an energy offer at an interval throws, naming it" begin
        sys, _ = nem_network(db; as_of = first(interval), through = last(interval) - Minute(5))
        wide = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 8)
        registered = registration_spans(read_units(db; as_of = first(wide), through = last(wide) - Minute(5)))
        @test_throws r"\w+ (GEN|LOAD) has no energy offer at" set_market_bids!(sys, db, wide; registered)
    end

    @testset "a non-scheduled load with an FCAS bid ends available and bids no energy" begin
        sys, _ = nem_network(db; as_of = first(interval), through = last(interval) - Minute(5))
        asload = get_component(NEMLoad, sys, "ASLOAD1")
        @test !get_available(asload)
        set_market_bids!(sys, db, interval)
        @test get_available(asload)
        @test !isempty(AEM.get_fcas_bids(get_operation_cost(asload)))
        @test isempty(AEM.get_energy_bids(get_operation_cost(asload)))
    end

    @testset "loss factors are kept in each bidding unit's ext" begin
        sys, _ = nem_network(db; as_of = first(interval), through = last(interval) - Minute(5))
        set_market_bids!(sys, db, interval)
        for storage in get_components(NEMStorage, sys)
            @test get_ext(storage)["nem_gen_loss_factor"] > 0.0
            @test get_ext(storage)["nem_load_loss_factor"] > 0.0
        end
    end
end
