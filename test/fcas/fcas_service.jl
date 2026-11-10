@testset "PSCB FCASService" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates

    config = HiveConfiguration(hive_location = AEM_TEST_PSCB_HIVE_DIR, filesystem = "file")
    db = aem_connect(config)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(2) + Minute(5))

    # Independently computed from the recorded bids, mirroring add_fcas_services!'s rules without
    # calling its helpers, so the test doesn't just re-assert the implementation.
    function _expected_services(sys)
        expected = Dict{String, Set{String}}()
        left_out = Dict{String, Set{String}}()
        for d in Iterators.flatten((get_components(Generator, sys), get_components(Storage, sys)))
            get_available(d) || continue
            region = get_name(get_area(get_bus(d)))
            for bid_type in FCAS_BID_TYPES
                sides = Set(
                    AustralianElectricityMarkets._fcas_bid_side(d, b) for b in AustralianElectricityMarkets.get_fcas_bids(AustralianElectricityMarkets._nem_offer_cost(d))
                        if b.service == bid_type
                )
                delete!(sides, nothing)
                inc, dec = OfferSide.GEN in sides, OfferSide.LOAD in sides
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
        sys = nem_pscb_system()
        (; added, excluded) = set_market_bids!(sys, db, date_range)
        expected, left_out = _expected_services(sys)
        @test !isempty(expected)

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
        sys = nem_pscb_system()
        first_added = set_market_bids!(sys, db, date_range).added
        added, _ = add_fcas_services!(sys)
        @test isempty(added)
        @test Set(get_name.(get_components(FCASService, sys))) == Set(first_added)
    end
end
