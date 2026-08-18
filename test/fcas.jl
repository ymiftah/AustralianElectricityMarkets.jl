@testset "FCAS types" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates
    using DataFrames

    hive_dir = AEM_TEST_HIVE_DIR
    config = HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(config)

    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))

    @testset "read_fcas_bids" begin
        bids = read_fcas_bids(db, date_range, BidType.RAISE6SEC)
        @test !isempty(bids)
        @test all(==(20.0), bids.ENABLEMENTMIN)
        @test all(==(100.0), bids.ENABLEMENTMAX)
        @test "piecewise_step_data" in names(bids)

        reg_bids = read_fcas_bids(db, date_range, BidType.RAISEREG)
        @test !isempty(reg_bids)
        @test all(==(1.0), reg_bids.ROCUP)
    end

    @testset "add_fcas_reserves!" begin
        sys = nem_system(db, RegionalNetworkConfiguration())
        regions = get_name.(get_components(Area, sys))
        reserves = add_fcas_reserves!(sys, regions)

        # 6 regions * 8 in-scope FCAS markets
        @test length(reserves) == 48
        @test length(collect(get_components(Reserve, sys))) == 48

        raise6sec = reserves["RAISE6SEC_NSW1"]
        @test raise6sec isa ContingencyFCASReserve{ReserveUp}
        @test get_response_time(raise6sec) == FCASResponseTime.SEC6
        @test get_region(raise6sec) === get_component(Area, sys, "NSW1")

        raisereg = reserves["RAISEREG_NSW1"]
        @test raisereg isa RegulationFCASReserve{ReserveUp}
        lowerreg = reserves["LOWERREG_NSW1"]
        @test lowerreg isa RegulationFCASReserve{ReserveDown}
    end

    @testset "FCASNetworkConfiguration" begin
        required_tables = table_requirements(FCASNetworkConfiguration())
        @test :DISPATCH_FCAS_REQ in required_tables
        @test :DISPATCHCONSTRAINT in required_tables
        @test :GENCONDATA in required_tables
        @test :DISPATCHLOAD in required_tables
        @test :BIDPEROFFER_D in required_tables

        sys = nem_system(db, FCASNetworkConfiguration())
        @test length(collect(get_components(Reserve, sys))) == 48
    end

    @testset "set_fcas_offers!" begin
        # operation_cost isn't touched here: PSY's generated device structs (e.g.
        # ThermalStandard.operation_cost::Union{ThermalGenerationCost, MarketBidCost}) use a
        # *closed* Union, so an externally-defined OfferCurveCost subtype like
        # NEMMarketBidCost can never be assigned there without modifying PowerSystems itself
        # - confirmed directly. set_fcas_offers! instead links devices to their reserve via
        # add_service!(device, reserve, sys) and stores the priced offer in ext.
        sys = nem_system(db, RegionalNetworkConfiguration())
        regions = get_name.(get_components(Area, sys))
        region_reserves = add_fcas_reserves!(sys, regions)

        set_fcas_offers!(sys, db, date_range, region_reserves)

        found_offer = false
        for gen in get_components(Generator, sys)
            offers = get(get_ext(gen), "fcas_offers", FCASOffer[])
            isempty(offers) && continue
            found_offer = true
            offer = first(offers)
            @test offer isa FCASOffer
            @test haskey(region_reserves, get_reserve_name(offer))
            @test get_trapezium(offer).enablement_min == 20.0
            reserve = region_reserves[get_reserve_name(offer)]
            @test gen in collect(get_contributing_devices(sys, reserve))
        end
        @test found_offer
    end

    @testset "read_fcas_requirements" begin
        req = read_fcas_requirements(db, date_range)
        @test !isempty(req)
        @test Set(["SETTLEMENTDATE", "REGIONID", "BIDTYPE", "GENCONID", "REQUIREMENT", "LHS", "MARGINALVALUE", "DESCRIPTION", "CONSTRAINTTYPE"]) ⊆ Set(names(req))
        @test BidType.RAISEREG in req.BIDTYPE
        raisereg_nsw = subset(req, :REGIONID => ByRow(==("NSW1")), :BIDTYPE => ByRow(==(BidType.RAISEREG)))
        @test all(==(30.0), raisereg_nsw.REQUIREMENT)
        @test all(==(2.25), raisereg_nsw.MARGINALVALUE)
        raise6sec_nsw = subset(req, :REGIONID => ByRow(==("NSW1")), :BIDTYPE => ByRow(==(BidType.RAISE6SEC)))
        @test all(==(50.0), raise6sec_nsw.REQUIREMENT)
        @test all(!ismissing, req.DESCRIPTION)
    end

    @testset "read_fcas_prices" begin
        prices = read_fcas_prices(db, date_range)
        @test !isempty(prices)
        @test Set(["SETTLEMENTDATE", "REGIONID", "BIDTYPE", "RRP", "ROP", "APCFLAG"]) == Set(names(prices))
        @test BidType.RAISEREG in prices.BIDTYPE
        raisereg_nsw = subset(prices, :REGIONID => ByRow(==("NSW1")), :BIDTYPE => ByRow(==(BidType.RAISEREG)))
        @test all(==(2.25), raisereg_nsw.RRP)
        @test all(==(2.25), raisereg_nsw.ROP)
    end

    @testset "read_prices" begin
        prices = read_prices(db, date_range)
        @test !isempty(prices)
        @test Set(["SETTLEMENTDATE", "REGIONID", "RRP", "ROP", "APCFLAG"]) == Set(names(prices))
        @test eltype(prices.RRP) == Float64
        first_interval = subset(prices, :SETTLEMENTDATE => ByRow(==(start_date)))
        @test all(==(50.0), first_interval.RRP)
        @test all(==(50.0), first_interval.ROP)
    end

    @testset "read_fcas_dispatch" begin
        dispatch = read_fcas_dispatch(db, date_range)
        @test !isempty(dispatch)
        @test Set(["SETTLEMENTDATE", "DUID", "INITIALMW", "TOTALCLEARED", "AVAILABILITY", "AGCSTATUS", "TARGET", "ACTUALAVAILABILITY", "BIDTYPE"]) == Set(names(dispatch))
        raise6sec = subset(dispatch, :BIDTYPE => ByRow(==(BidType.RAISE6SEC)))
        @test all(==(5.0), raise6sec.TARGET)
        @test all(==(5.0), raise6sec.ACTUALAVAILABILITY)
        raisereg = subset(dispatch, :BIDTYPE => ByRow(==(BidType.RAISEREG)))
        @test all(==(3.0), raisereg.TARGET)
        @test all(ismissing, raisereg.ACTUALAVAILABILITY)
    end

    @testset "FCAS price decomposition identity" begin
        # Regional FCAS price = sum of MARGINALVALUE over the constraints governing that
        # (region, market) - the mock has exactly one governing constraint per pair, so the
        # sum degenerates to a single value; real NEMWEB data can have several (see docs).
        req = read_fcas_requirements(db, date_range)
        prices = read_fcas_prices(db, date_range)
        derived = combine(
            groupby(req, [:SETTLEMENTDATE, :REGIONID, :BIDTYPE]),
            :MARGINALVALUE => sum => :derived_price,
        )
        joined = innerjoin(derived, prices, on = [:SETTLEMENTDATE, :REGIONID, :BIDTYPE])
        @test !isempty(joined)
        @test all(isapprox.(joined.derived_price, joined.ROP; atol = 1.0e-6))
    end

    @testset "JSON round-trip" begin
        # Deliberately skips set_market_bids! here: this repo's existing energy bid path
        # sets no_load_cost=0.0, and PowerSystems.MarketBidCost's constructor can't convert
        # the Int64 a whole-number Float64 becomes after a JSON round-trip back into the
        # Float64 it needs - a pre-existing PSY/JSON3 interaction bug, confirmed unrelated
        # to FCAS (it reproduces with plain MarketBidCost, no FCAS types involved) and out of
        # scope to fix here. This testset isolates the FCAS-specific round-trip behavior.
        sys = nem_system(db, RegionalNetworkConfiguration())
        regions = get_name.(get_components(Area, sys))
        region_reserves = add_fcas_reserves!(sys, regions)
        set_fcas_offers!(sys, db, date_range, region_reserves)

        mktpath = mktempdir()
        json_path = joinpath(mktpath, "sys.json")
        to_json(sys, json_path)
        sys2 = System(json_path)

        r1 = get_component(Reserve, sys, "RAISE6SEC_NSW1")
        r2 = get_component(Reserve, sys2, "RAISE6SEC_NSW1")
        @test !isnothing(r2)
        @test r2 isa ContingencyFCASReserve{ReserveUp}
        @test get_name(r1) == get_name(r2)
        @test get_response_time(r1) == get_response_time(r2)
        @test get_requirement(r1) == get_requirement(r2)
        @test length(collect(get_components(Reserve, sys2))) == 48

        found_offer = false
        for gen in get_components(Generator, sys2)
            ext = get_ext(gen)
            haskey(ext, "fcas_offers") || continue
            offers = ext["fcas_offers"]
            isempty(offers) && continue
            found_offer = true
            # ext round-trips as plain Dicts, not reconstructed FCASOffer structs (see
            # set_fcas_offers! docstring) - assert on the dict shape accordingly.
            @test offers[1]["trapezium"]["enablement_min"] == 20.0
            reserve_name = offers[1]["reserve_name"]
            reserve2 = get_component(Reserve, sys2, reserve_name)
            @test gen in collect(get_contributing_devices(sys2, reserve2))
        end
        @test found_offer
    end
end
