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

    @testset "FCASTrapezium slope coefficients" begin
        t = FCASTrapezium(;
            enablement_min = 1.0, low_breakpoint = 5.0, high_breakpoint = 9.0,
            enablement_max = 13.0, max_avail = 4.0,
        )
        @test get_lower_slope_coeff(t) == (5.0 - 1.0) / 4.0
        @test get_upper_slope_coeff(t) == (13.0 - 9.0) / 4.0

        zero_avail = FCASTrapezium(;
            enablement_min = 1.0, low_breakpoint = 5.0, high_breakpoint = 9.0,
            enablement_max = 13.0, max_avail = 0.0,
        )
        @test get_lower_slope_coeff(zero_avail) == 0.0
        @test get_upper_slope_coeff(zero_avail) == 0.0
    end

    @testset "Tuple/FCASTrapezium round trip" begin
        # Regulation markets: both ramp rates present.
        with_ramps = FCASTrapezium(;
            enablement_min = 1.0, low_breakpoint = 5.0, high_breakpoint = 9.0,
            enablement_max = 13.0, max_avail = 4.0, ramp_up_rate = 2.0, ramp_down_rate = 3.0,
        )
        t = Tuple(with_ramps)
        @test t isa NTuple{7, Float64}
        @test t == (1.0, 5.0, 9.0, 13.0, 4.0, 2.0, 3.0)
        back = FCASTrapezium(t)
        @test back == with_ramps

        # Non-regulation markets: both ramp rates nothing -> NaN -> nothing. NaN != NaN, so
        # `==` on the tuple is wrong here - use isequal.
        no_ramps = FCASTrapezium(;
            enablement_min = 20.0, low_breakpoint = 30.0, high_breakpoint = 90.0,
            enablement_max = 100.0, max_avail = 10.0,
        )
        nt = Tuple(no_ramps)
        @test isnan(nt[6])
        @test isnan(nt[7])
        @test isequal(nt, (20.0, 30.0, 90.0, 100.0, 10.0, NaN, NaN))
        @test isequal(FCASTrapezium(nt), no_ramps)
    end

    @testset "_fcas_trapezium_points throws an actionable error on a missing required field" begin
        row = (
            DIRECTION = "GEN", PRICEBANDARRAY = [10.0, 20.0], BANDAVAILARRAY = [5.0, 5.0],
            DUID = "BW01", ENABLEMENTMIN = missing, LOWBREAKPOINT = 30.0, HIGHBREAKPOINT = 90.0,
            ENABLEMENTMAX = 100.0, MAXAVAIL = 10.0, ROCUP = missing, ROCDOWN = missing,
        )
        err = try
            AustralianElectricityMarkets._fcas_trapezium_points(row)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("ENABLEMENTMIN", err.msg)
        @test occursin("BW01", err.msg)
    end

    @testset "_fcas_trapezium_points rejects a malformed trapezium" begin
        base_row = (
            DIRECTION = "GEN", PRICEBANDARRAY = [10.0, 20.0], BANDAVAILARRAY = [5.0, 5.0],
            DUID = "BW01", ENABLEMENTMIN = 10.0, LOWBREAKPOINT = 30.0, HIGHBREAKPOINT = 90.0,
            ENABLEMENTMAX = 100.0, MAXAVAIL = 10.0, ROCUP = missing, ROCDOWN = missing,
        )
        # Well-formed, including the degenerate vertical and triangular shapes.
        @test AustralianElectricityMarkets._fcas_trapezium_points(base_row) isa AustralianElectricityMarkets.FCASTrapeziumPoints
        vertical = merge(base_row, (ENABLEMENTMIN = 0.0, LOWBREAKPOINT = 0.0, HIGHBREAKPOINT = 0.0, ENABLEMENTMAX = 0.0))
        @test AustralianElectricityMarkets._fcas_trapezium_points(vertical) isa AustralianElectricityMarkets.FCASTrapeziumPoints
        triangle = merge(base_row, (LOWBREAKPOINT = 50.0, HIGHBREAKPOINT = 50.0))
        @test AustralianElectricityMarkets._fcas_trapezium_points(triangle) isa AustralianElectricityMarkets.FCASTrapeziumPoints

        for bad in (
                (LOWBREAKPOINT = 5.0,),                         # LowBreakpoint < EnablementMin
                (LOWBREAKPOINT = 95.0,),                        # LowBreakpoint > HighBreakpoint
                (HIGHBREAKPOINT = 110.0,),                      # HighBreakpoint > EnablementMax
                (ENABLEMENTMIN = 120.0, LOWBREAKPOINT = 120.0), # EnablementMin > EnablementMax
                (MAXAVAIL = -1.0,),
            )
            err = try
                AustralianElectricityMarkets._fcas_trapezium_points(merge(base_row, bad))
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("Malformed FCAS trapezium", err.msg)
            @test occursin("BW01", err.msg)
        end
    end

    @testset "fcas_service throws when a device has two services of one market" begin
        sys = first(nem_network(db))
        set_market_bids!(sys, db, date_range)
        asload1 = get_component(InterruptiblePowerLoad, sys, "ASLOAD1")
        @test fcas_service(asload1, BidType.RAISE6SEC) isa FCASService
        extra = FCASService(; name = "NSW1_RAISE6SEC_EXTRA", region = "NSW1", bid_type = BidType.RAISE6SEC)
        add_service!(sys, extra, [asload1])
        @test_throws ArgumentError fcas_service(asload1, BidType.RAISE6SEC)
    end

    @testset "read_fcas_bids" begin
        bids = read_fcas_bids(db, date_range, BidType.RAISE6SEC)
        @test !isempty(bids)
        # ASLOAD1, a non-scheduled load, bids the point trapezium (0, 0, 0, 0).
        asload = bids.DUID .== "ASLOAD1"
        @test any(asload)
        @test all(==(20.0), bids.ENABLEMENTMIN[.!asload])
        @test all(==(100.0), bids.ENABLEMENTMAX[.!asload])
        @test all(==(0.0), bids.ENABLEMENTMAX[asload])
        @test "PRICEBANDARRAY" in names(bids) && "BANDAVAILARRAY" in names(bids)

        reg_bids = read_fcas_bids(db, date_range, BidType.RAISEREG)
        @test !isempty(reg_bids)
        @test all(ismissing, reg_bids.ROCUP)

        both = read_fcas_bids(db, date_range, [BidType.RAISE6SEC, BidType.RAISEREG])
        @test all(b -> b isa BidType, both.BIDTYPE)
        @test isequal(select(subset(both, :BIDTYPE => ByRow(==(BidType.RAISE6SEC))), Not(:BIDTYPE)), bids)
        @test isequal(select(subset(both, :BIDTYPE => ByRow(==(BidType.RAISEREG))), Not(:BIDTYPE)), reg_bids)
    end

    @testset "FCAS period fields share the price and quantity rows" begin
        R = AustralianElectricityMarkets.Readers
        markets = [BidType.RAISE6SEC, BidType.RAISEREG]
        projected = R._massage_bids(
            db, first(date_range), last(date_range); bid_types = markets,
            keep_bid_type = true, period_columns = R._FCAS_TRAPEZIUM_COLUMNS,
        )
        expected = read_fcas_bids(db, date_range, markets)
        transform!(projected, :BIDTYPE => ByRow(BidType) => :BIDTYPE)
        keys = [:SETTLEMENTDATE, :INTERVAL_DATETIME, :DUID, :DIRECTION, :BIDTYPE]
        @test isequal(sort(projected, keys), sort(expected, keys))
        @test_throws ArgumentError R._massage_bids(
            db, first(date_range), last(date_range); resolution = Minute(15),
            period_columns = R._FCAS_TRAPEZIUM_COLUMNS,
        )
        for resolution in (nothing, Minute(5), Minute(15))
            bands = R._massage_bids(db, first(date_range), last(date_range); bid_types = markets, keep_bid_type = true, resolution)
            trapezium = R._read_period_offers(db, markets, first(date_range), last(date_range), nothing; columns = R._FCAS_TRAPEZIUM_COLUMNS)
            legacy = innerjoin(bands, trapezium; on = keys)
            transform!(legacy, :BIDTYPE => ByRow(BidType) => :BIDTYPE)
            actual = read_fcas_bids(db, date_range, markets; resolution)
            @test isequal(sort(actual, keys), sort(legacy, keys))
        end
    end

    @testset "a non-scheduled load offering FCAS joins its region's services" begin
        sys = first(nem_network(db))
        (; added, excluded) = set_market_bids!(sys, db, date_range)
        asload1 = get_component(InterruptiblePowerLoad, sys, "ASLOAD1")
        @test "NSW1_RAISE6SEC" in added
        svc = get_component(FCASService, sys, "NSW1_RAISE6SEC")
        @test has_service(asload1, svc)
        other_loads = filter(l -> get_name(l) != "ASLOAD1", collect(get_components(InterruptiblePowerLoad, sys)))
        @test !any(l -> has_service(l, svc), other_loads)
        @test !haskey(excluded, "NSW1_RAISE6SEC") || !("ASLOAD1" in excluded["NSW1_RAISE6SEC"])
    end

    @testset "read_fcas_requirements" begin
        req = read_fcas_requirements(db, date_range)
        @test !isempty(req)
        @test Set(["SETTLEMENTDATE", "REGIONID", "BIDTYPE", "GENCONID", "REQUIREMENT", "LHS", "MARGINALVALUE", "DESCRIPTION", "CONSTRAINTTYPE"]) ⊆ Set(names(req))
        @test BidType.RAISEREG in req.BIDTYPE
        # DISPATCHCONSTRAINT.RHS varies per interval as requirement_mw(bid_type) + 0.1*i
        # (mock_data.jl step 14) - check the exact per-interval series, not a flat value.
        raisereg_nsw = sort(subset(req, :REGIONID => ByRow(==("NSW1")), :BIDTYPE => ByRow(==(BidType.RAISEREG))), :SETTLEMENTDATE)
        @test raisereg_nsw.REQUIREMENT ≈ [30.0 + 0.1 * i for i in 0:(nrow(raisereg_nsw) - 1)]
        @test all(==(2.25), raisereg_nsw.MARGINALVALUE)
        raise6sec_nsw = sort(subset(req, :REGIONID => ByRow(==("NSW1")), :BIDTYPE => ByRow(==(BidType.RAISE6SEC))), :SETTLEMENTDATE)
        @test raise6sec_nsw.REQUIREMENT ≈ [50.0 + 0.1 * i for i in 0:(nrow(raise6sec_nsw) - 1)]
        @test all(!ismissing, req.DESCRIPTION)
    end

    @testset "the 1-second markets are read as FCAS markets" begin
        req = read_fcas_requirements(db, date_range)
        for bid_type in (BidType.RAISE1SEC, BidType.LOWER1SEC)
            @test bid_type in FCAS_CONTINGENCY_MARKETS
            rows = subset(req, :BIDTYPE => ByRow(==(bid_type)))
            @test !isempty(rows)
            @test all(==(5.5), rows.MARGINALVALUE)
        end
        prices = read_fcas_prices(db, date_range)
        @test BidType.RAISE1SEC in prices.BIDTYPE && BidType.LOWER1SEC in prices.BIDTYPE
        dispatch = read_fcas_dispatch(db, date_range)
        raise1sec = subset(dispatch, :BIDTYPE => ByRow(==(BidType.RAISE1SEC)))
        @test !isempty(raise1sec)
        @test all(==(5.0), raise1sec.ACTUALAVAILABILITY)
        bids = read_fcas_bids(db, date_range, BidType.RAISE1SEC)
        @test !isempty(bids)
        sys = first(nem_network(db))
        set_market_bids!(sys, db, date_range)
        @test any(
            g -> has_time_series(g, SingleTimeSeries, AustralianElectricityMarkets.bid_series_name(BidType.RAISE1SEC, :trapezium, AustralianElectricityMarkets.BidDirection.GEN)),
            get_components(Generator, sys),
        )
    end

    @testset "read_fcas_requirements spans the DISPATCH_FCAS_REQ split" begin
        # Past interval 24 only DISPATCH_FCAS_REQ_CONSTRAINT has rows (mock_data.jl step 13).
        new_only_range = (start_date + Minute(5 * 30)):Minute(5):(start_date + Minute(5 * 40))
        req = read_fcas_requirements(db, new_only_range)
        @test !isempty(req)
        @test BidType.RAISEREG in req.BIDTYPE
        # One row per (SETTLEMENTDATE, REGIONID, BIDTYPE, GENCONID) - the QUALIFY in the
        # union must not fan out against GENCONDATA's version rows.
        @test nrow(req) == nrow(unique(select(req, :SETTLEMENTDATE, :REGIONID, :BIDTYPE, :GENCONID)))
        # DESCRIPTION still resolves post-split even though the new table dropped
        # GENCONEFFECTIVEDATE/GENCONVERSIONNO - via the latest-version-at-interval fallback.
        @test all(!ismissing, req.DESCRIPTION)
    end

    @testset "read_fcas_requirements throws when neither FCAS_REQ table is cached" begin
        # DISPATCHCONSTRAINT/GENCONDATA must stay cached here (read_fcas_requirements queries
        # their schema before reaching the FCAS_REQ check) - only the FCAS_REQ tables are
        # missing, reproducing the AEMO 2025-05/2025-06 changeover with nothing downloaded yet.
        partial_hive = mktempdir()
        create_mock_data(partial_hive)
        rm(joinpath(partial_hive, "DISPATCH_FCAS_REQ"); recursive = true)
        rm(joinpath(partial_hive, "DISPATCH_FCAS_REQ_CONSTRAINT"); recursive = true)
        partial_db = aem_connect(HiveConfiguration(hive_location = partial_hive, filesystem = "file"))
        err = try
            read_fcas_requirements(partial_db, date_range)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("DISPATCH_FCAS_REQ", err.msg)
        @test occursin("DISPATCH_FCAS_REQ_CONSTRAINT", err.msg)
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

end
