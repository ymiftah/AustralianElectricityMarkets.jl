@testset "PSCB FCASService" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates

    config = HiveConfiguration(hive_location = AEM_TEST_PSCB_HIVE_DIR, filesystem = "file")
    db = aem_connect(config)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(2) + Minute(5))

    # Independently computed from the series names, mirroring add_fcas_services!'s rules without
    # calling its helpers, so the test doesn't just re-assert the implementation.
    function _expected_services(sys)
        expected = Dict{String, Set{String}}()
        left_out = Dict{String, Set{String}}()
        for d in Iterators.flatten((get_components(Generator, sys), get_components(Storage, sys)))
            get_available(d) || continue
            region = get_name(get_area(get_bus(d)))
            for bid_type in FCAS_BID_TYPES
                inc = has_time_series(d, Deterministic, "fcas_trapezium_$(string(bid_type))")
                dec = has_time_series(d, Deterministic, "fcas_trapezium_$(string(bid_type))_decremental")
                (inc || dec) || continue
                name = "$(region)_$(string(bid_type))"
                modeled = (inc && !dec) || (dec && !inc && d isa Storage) ||
                    (inc && dec && d isa Storage && bid_type in FCAS_REGULATION_MARKETS)
                push!(get!(modeled ? expected : left_out, name, Set{String}()), get_name(d))
            end
        end
        return expected, left_out
    end

    @testset "add_fcas_services! builds one service per bid (region, bid_type), modeled bids only" begin
        sys = augmented_pscb_system()
        set_fcas_bids!(sys, db, date_range)
        expected, left_out = _expected_services(sys)
        @test !isempty(expected)
        added, excluded = add_fcas_services!(sys)

        @test Set(added) == Set(keys(expected))
        @test Dict(k => Set(v) for (k, v) in excluded) == left_out
        for (name, devices) in expected
            svc = get_component(FCASService, sys, name)
            @test get_region(svc) * "_" * string(get_bid_type(svc)) == name
            contributors = Set(
                get_name(d) for d in Iterators.flatten((get_components(Generator, sys), get_components(Storage, sys)))
                    if has_service(d, svc)
            )
            @test contributors == devices
        end
        # BAT1 bids RAISE6SEC in both directions, which the formulation does not model.
        @test "BAT1" in excluded["1_RAISE6SEC"]
    end

    @testset "a second call adds nothing and keeps the existing services" begin
        sys = augmented_pscb_system()
        set_fcas_bids!(sys, db, date_range)
        first_added, _ = add_fcas_services!(sys)
        added, _ = add_fcas_services!(sys)
        @test isempty(added)
        @test Set(get_name.(get_components(FCASService, sys))) == Set(first_added)
    end

    @testset "an unavailable bidder is not attached" begin
        sys = augmented_pscb_system()
        set_fcas_bids!(sys, db, date_range)
        alta = get_component(ThermalStandard, sys, "Alta")
        set_available!(alta, false)
        add_fcas_services!(sys)
        @test !any(s -> has_service(alta, s), get_components(FCASService, sys))
    end

    @testset "device with only a decremental bid series still contributes" begin
        # Neither this fixture nor mock_data.jl ever produces a decremental-only device -
        # every DUID that gets a LOAD row (BAT1 here, BW01 in mock_data.jl) also gets a
        # matching GEN row for the same bid type. Constructed directly instead: BAT1 gets
        # only manual decremental RAISE6SEC series, and no other device gets any at all.
        sys = augmented_pscb_system()
        bat = get_component(EnergyReservoirStorage, sys, "BAT1")
        add_time_series!(
            sys, bat,
            Deterministic(;
                name = "fcas_curve_RAISE6SEC_decremental",
                # Deterministic requires at least 2 points per forecast window.
                data = Dict(start_date => fill(PiecewiseStepData([0.0, 5.0], [10.0]), 2)),
                resolution = Minute(5), interval = Minute(5),
            ),
        )
        add_time_series!(
            sys, bat,
            Deterministic(;
                name = "fcas_trapezium_RAISE6SEC_decremental",
                data = Dict(start_date => fill((0.0, 0.0, 5.0, 5.0, 5.0, NaN, NaN), 2)),
                resolution = Minute(5), interval = Minute(5),
            ),
        )

        added, _ = add_fcas_services!(sys)
        @test "1_RAISE6SEC" in added
        svc = get_component(FCASService, sys, "1_RAISE6SEC")
        @test has_service(bat, svc)
    end

    @testset "get_region/get_bid_type accessors" begin
        svc = FCASService(; name = "1_RAISE6SEC", region = "1", bid_type = BidType.RAISE6SEC)
        @test get_region(svc) == "1"
        @test get_bid_type(svc) == BidType.RAISE6SEC
    end
end
