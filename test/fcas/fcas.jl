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

    @testset "_extract_fcas_bid throws an actionable error on a missing required field" begin
        row = (
            DIRECTION = "GEN", PRICEBANDARRAY = [10.0, 20.0], BANDAVAILARRAY = [5.0, 5.0],
            DUID = "BW01", ENABLEMENTMIN = missing, LOWBREAKPOINT = 30.0, HIGHBREAKPOINT = 90.0,
            ENABLEMENTMAX = 100.0, MAXAVAIL = 10.0, ROCUP = missing, ROCDOWN = missing,
        )
        err = try
            AustralianElectricityMarkets._extract_fcas_bid(row)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("ENABLEMENTMIN", err.msg)
        @test occursin("BW01", err.msg)
    end

    @testset "_extract_fcas_bid rejects a malformed trapezium" begin
        base_row = (
            DIRECTION = "GEN", PRICEBANDARRAY = [10.0, 20.0], BANDAVAILARRAY = [5.0, 5.0],
            DUID = "BW01", ENABLEMENTMIN = 10.0, LOWBREAKPOINT = 30.0, HIGHBREAKPOINT = 90.0,
            ENABLEMENTMAX = 100.0, MAXAVAIL = 10.0, ROCUP = missing, ROCDOWN = missing,
        )
        # Well-formed, including the degenerate vertical and triangular shapes.
        @test AustralianElectricityMarkets._extract_fcas_bid(base_row) isa Tuple
        vertical = merge(base_row, (ENABLEMENTMIN = 0.0, LOWBREAKPOINT = 0.0, HIGHBREAKPOINT = 0.0, ENABLEMENTMAX = 0.0))
        @test AustralianElectricityMarkets._extract_fcas_bid(vertical) isa Tuple
        triangle = merge(base_row, (LOWBREAKPOINT = 50.0, HIGHBREAKPOINT = 50.0))
        @test AustralianElectricityMarkets._extract_fcas_bid(triangle) isa Tuple

        for bad in (
                (LOWBREAKPOINT = 5.0,),                         # LowBreakpoint < EnablementMin
                (LOWBREAKPOINT = 95.0,),                        # LowBreakpoint > HighBreakpoint
                (HIGHBREAKPOINT = 110.0,),                      # HighBreakpoint > EnablementMax
                (ENABLEMENTMIN = 120.0, LOWBREAKPOINT = 120.0), # EnablementMin > EnablementMax
                (MAXAVAIL = -1.0,),
            )
            err = try
                AustralianElectricityMarkets._extract_fcas_bid(merge(base_row, bad))
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("Malformed FCAS trapezium", err.msg)
            @test occursin("BW01", err.msg)
        end
    end

    @testset "_get_fcas_trapezium/_get_fcas_offer_curve" begin
        sys = first(nem_network(db))
        set_fcas_bids!(sys, db, date_range)
        set_market_bids!(sys, db, date_range)
        set_fcas_service_bids!(sys, db, date_range)
        horizon = length(date_range) - 1

        # Only zero-cost devices carry offer curves; ASLOAD1 is a zero-cost non-scheduled load.
        asload1 = get_component(NEMLoad, sys, "ASLOAD1")
        trapeziums = AustralianElectricityMarkets._get_fcas_trapezium(asload1, BidType.RAISE6SEC, start_date, horizon; decremental = true)
        curves = AustralianElectricityMarkets._get_fcas_offer_curve(asload1, BidType.RAISE6SEC, start_date, horizon; decremental = true)
        @test trapeziums isa Vector{FCASTrapezium}
        @test curves isa Vector{PiecewiseStepData}
        @test length(trapeziums) == length(curves) == horizon
        offer = get_fcas_offer(asload1, BidType.RAISE6SEC, OfferSide.LOAD, start_date, horizon)
        @test offer isa NEMFCASOffer && offer.service == BidType.RAISE6SEC && offer.side == OfferSide.LOAD
        @test offer.trapeziums == trapeziums && offer.curves == curves

        # A generator carries its offer curve once FCAS service bids are stored.
        gen = first(g for g in get_components(Generator, sys) if has_time_series(g, SingleTimeSeries, "fcas_trapezium_RAISE6SEC"))
        @test !isempty(AustralianElectricityMarkets._get_fcas_trapezium(gen, BidType.RAISE6SEC, start_date, horizon))
        @test length(AustralianElectricityMarkets._get_fcas_offer_curve(gen, BidType.RAISE6SEC, start_date, horizon)) == horizon

        # BW01 bids RAISE6SEC both ways on a non-regulation market, which the formulation does not
        # model: it has no service, so its trapezium is readable but it has no offer curves.
        bw01 = get_component(NEMStorage, sys, "BW01")
        @test !any(s -> s isa FCASService && get_bid_type(s) == BidType.RAISE6SEC, get_services(bw01))
        @test_throws ArgumentError AustralianElectricityMarkets._get_fcas_offer_curve(bw01, BidType.RAISE6SEC, start_date, horizon; decremental = true)

        # decremental = true reads a genuinely separate series: it succeeds for BW01 (which
        # has both directions attached) but throws for a Generator (incremental-only), proving
        # it isn't just re-reading the incremental series under a different name.
        dec_trapeziums = AustralianElectricityMarkets._get_fcas_trapezium(bw01, BidType.RAISE6SEC, start_date, horizon; decremental = true)
        @test dec_trapeziums isa Vector{FCASTrapezium}
        @test length(dec_trapeziums) == horizon
        @test_throws ArgumentError AustralianElectricityMarkets._get_fcas_trapezium(
            first(get_components(Generator, sys)), BidType.RAISE6SEC, start_date, horizon; decremental = true,
        )

        # A component with no FCAS series attached at all throws, naming what's missing.
        no_bids_sys = first(nem_network(db))
        no_bids_gen = first(get_components(Generator, no_bids_sys))
        err = try
            AustralianElectricityMarkets._get_fcas_trapezium(no_bids_gen, BidType.RAISE6SEC, start_date, horizon)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("RAISE6SEC", err.msg)
    end

    @testset "service bids are stored in MW and read per-unit" begin
        sys = first(nem_network(db))
        set_fcas_bids!(sys, db, date_range)
        set_market_bids!(sys, db, date_range)
        set_fcas_service_bids!(sys, db, date_range)
        base_power = get_base_power(sys)

        asload1 = get_component(NEMLoad, sys, "ASLOAD1")
        name = fcas_offer_series_name(fcas_service(asload1, BidType.RAISE6SEC), true)
        stored = get_time_series_values(SingleTimeSeries, asload1, name)
        _, gdf_dec = AustralianElectricityMarkets._fcas_bid_groups(read_fcas_bids(db, date_range, BidType.RAISE6SEC), base_power)
        expected = gdf_dec[("ASLOAD1",)].curve_data
        @test length(stored) == length(expected)
        # The stored curve is the bid in MW, not divided by the system base.
        @test all(get_x_coords(s) == get_x_coords(e) for (s, e) in zip(stored, expected))

        # The reader divides by the system base under SYSTEM_BASE and returns MW under NATURAL_UNITS.
        with_units_base(sys, "SYSTEM_BASE") do
            curves = AustralianElectricityMarkets._get_fcas_offer_curve(
                asload1, BidType.RAISE6SEC, start_date, length(stored); decremental = true,
            )
            @test all(get_x_coords(c) ≈ get_x_coords(e) ./ base_power for (c, e) in zip(curves, expected))
        end
        with_units_base(sys, "NATURAL_UNITS") do
            curves = AustralianElectricityMarkets._get_fcas_offer_curve(
                asload1, BidType.RAISE6SEC, start_date, length(stored); decremental = true,
            )
            @test all(get_x_coords(c) ≈ get_x_coords(e) for (c, e) in zip(curves, expected))
        end
    end

    @testset "fcas_service throws when a device has two services of one market" begin
        sys = first(nem_network(db))
        set_fcas_bids!(sys, db, date_range)
        asload1 = get_component(NEMLoad, sys, "ASLOAD1")
        @test fcas_service(asload1, BidType.RAISE6SEC) isa FCASService
        extra = FCASService(; name = "NSW1_RAISE6SEC_EXTRA", region = "NSW1", bid_type = BidType.RAISE6SEC)
        add_service!(sys, extra, [asload1])
        @test_throws ArgumentError fcas_service(asload1, BidType.RAISE6SEC)
    end

    @testset "_require_equal_length throws on mismatched trapezium/curve series lengths" begin
        trapeziums = FCASTrapezium[
            FCASTrapezium(;
                enablement_min = 1.0, low_breakpoint = 2.0, high_breakpoint = 3.0,
                enablement_max = 4.0, max_avail = 5.0,
            ),
        ]
        curves = PiecewiseStepData[
            PiecewiseStepData([0.0, 1.0], [1.0]), PiecewiseStepData([0.0, 1.0], [1.0]),
        ]

        # Create a simple mock component for testing
        mock_bus = ACBus(; number = 1, name = "BW01", available = true, bustype = ACBusTypes.REF, angle = 0.0, magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1), base_voltage = 130.0)

        err = try
            AustralianElectricityMarkets._require_equal_length(trapeziums, curves, BidType.RAISE6SEC, mock_bus)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("RAISE6SEC", err.msg)
        @test occursin("BW01", err.msg)
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
        @test all(==(1.0), reg_bids.ROCUP)

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

    @testset "set_fcas_bids!" begin
        # A SingleTimeSeries trapezium per (component, market) and the offer curve as the
        # device's service bid.
        sys = first(nem_network(db))
        set_fcas_bids!(sys, db, date_range)
        set_market_bids!(sys, db, date_range)
        set_fcas_service_bids!(sys, db, date_range)
        base_power = get_base_power(sys)

        found = false
        for gen in get_components(Generator, sys)
            # has_time_series (not get_time_series + isnothing): get_time_series throws
            # ArgumentError, rather than returning nothing, for an owner with no metadata
            # registered at all for (SingleTimeSeries, name) - confirmed directly.
            has_time_series(gen, SingleTimeSeries, "fcas_trapezium_RAISE6SEC") || continue
            found = true
            trapezium_ts = get_time_series(SingleTimeSeries, gen, "fcas_trapezium_RAISE6SEC")
            # Generators carry their offer curve once FCAS service bids are stored.
            @test has_time_series(gen, SingleTimeSeries, fcas_offer_series_name(fcas_service(gen, BidType.RAISE6SEC), false))
            @test !isnothing(trapezium_ts)
            trap_rows = get_time_series_values(SingleTimeSeries, gen, "fcas_trapezium_RAISE6SEC")
            # Raw stored series is per-unit of sys's base power - _get_fcas_trapezium (tested
            # above) is what converts back to MW.
            @test first(trap_rows)[1] == 20.0 / base_power
        end
        @test found

        # BW01's LOAD-direction FCAS bids attach to its NEMStorage component
        # under the "_decremental" suffix, not dropped like an earlier version of
        # set_fcas_bids! dropped every non-GEN DIRECTION row.
        bw01 = get_component(NEMStorage, sys, "BW01")
        @test !isnothing(bw01)
        @test has_time_series(bw01, SingleTimeSeries, "fcas_trapezium_RAISE6SEC_decremental")

        # A non-scheduled load (no energy bid) that offers FCAS gets the decremental series and
        # becomes available; one with no FCAS bid stays unavailable. Scheduled loads are untouched.
        asload1 = get_component(NEMLoad, sys, "ASLOAD1")
        @test get_available(asload1)
        @test has_time_series(asload1, SingleTimeSeries, fcas_offer_series_name(fcas_service(asload1, BidType.RAISE6SEC), true))
        @test !has_time_series(asload1, SingleTimeSeries, "fcas_trapezium_RAISE6SEC")
        trap = AustralianElectricityMarkets._get_fcas_trapezium(asload1, BidType.RAISE6SEC, first(date_range), 3; decremental = true)
        @test all(t -> get_enablement_max(t) == 0.0 && get_max_avail(t) ≈ 15.0 / base_power, trap)
        @test !get_available(get_component(NEMLoad, sys, "ASLOAD2"))
        pump = get_component(NEMLoad, sys, "PUMP1")
        @test !any(s -> s isa FCASService && get_bid_type(s) == BidType.RAISE6SEC, get_services(pump))
    end

    @testset "set_fcas_offer! stores the curves under fcas_offer_<market>" begin
        sys = first(nem_network(db))
        set_fcas_bids!(sys, db, date_range)
        gen = first(g for g in get_components(Generator, sys) if has_time_series(g, SingleTimeSeries, "fcas_trapezium_RAISE6SEC"))
        cost = get_operation_cost(gen)
        curve(price) = PiecewiseStepData([0.0, 5.0], [price])
        series(name, price) = AustralianElectricityMarkets.single_series(name, start_date, fill(curve(price), 2), Minute(5))
        set_fcas_offer!(sys, gen, BidType.RAISE6SEC, OfferSide.GEN, series("anything", 10.0))
        @test has_time_series(gen, SingleTimeSeries, "fcas_offer_RAISE6SEC")
        @test !has_time_series(gen, SingleTimeSeries, "anything")
        @test get_time_series_values(SingleTimeSeries, gen, "fcas_offer_RAISE6SEC") == fill(curve(10.0), 2)
        @test get_operation_cost(gen) === cost
        set_fcas_offer!(sys, gen, BidType.RAISE6SEC, OfferSide.GEN, series("anything", 20.0))
        @test get_time_series_values(SingleTimeSeries, gen, "fcas_offer_RAISE6SEC") == fill(curve(20.0), 2)
        flat = AustralianElectricityMarkets.single_series("flat", start_date, [1.0, 2.0], Minute(5))
        @test_throws ArgumentError set_fcas_offer!(sys, gen, BidType.RAISE6SEC, OfferSide.GEN, flat)
    end

    @testset "set_fcas_offer! records the bid on a NEMOfferCost" begin
        sys = System(100.0)
        bus = ACBus(;
            number = 1, name = "bus", available = true, bustype = ACBusTypes.REF, angle = 0.0,
            magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1), base_voltage = 230.0,
        )
        add_component!(sys, bus)
        gen = NEMThermalGen(;
            name = "g", available = true, status = true, bus, active_power = 50.0, reactive_power = 0.0, rating = 120.0,
            active_power_limits = (min = 10.0, max = 100.0), reactive_power_limits = (min = -5.0, max = 5.0),
            ramp_limits = (up = 2.0, down = 3.0), base_power = 100.0, time_limits = (up = 1.0, down = 2.0),
            prime_mover_type = PrimeMovers.ST, fuel = ThermalFuels.COAL, operation_cost = NEMOfferCost(),
        )
        add_component!(sys, gen)
        svc = FCASService(; name = "svc", region = "NSW1", bid_type = BidType.RAISE6SEC)
        add_service!(sys, svc, [gen])
        single(name, v) = AustralianElectricityMarkets.single_series(name, start_date, fill(v, 2), Minute(5))
        curve = PiecewiseStepData([0.0, 5.0], [10.0])
        @test_throws ArgumentError set_fcas_offer!(sys, gen, BidType.LOWER6SEC, OfferSide.GEN, single("o", curve))
        # The bid needs the trapezium series it pairs with.
        @test_throws ArgumentError set_fcas_offer!(sys, gen, BidType.RAISE6SEC, OfferSide.GEN, single("o", curve))
        @test !has_time_series(gen, SingleTimeSeries, "fcas_offer_RAISE6SEC")
        add_time_series!(sys, gen, single("fcas_trapezium_RAISE6SEC", (0.0, 0.0, 1.0, 1.0, 1.0, NaN, NaN)))
        set_fcas_offer!(sys, gen, BidType.RAISE6SEC, OfferSide.GEN, single("o", curve))
        bids = get_fcas_bids(get_operation_cost(gen))
        @test length(bids) == 1
        @test bids[1].service == BidType.RAISE6SEC && bids[1].side == OfferSide.GEN
        @test bids[1].curves.name == "fcas_offer_RAISE6SEC"
        @test bids[1].trapezium.name == "fcas_trapezium_RAISE6SEC"
        set_fcas_offer!(sys, gen, BidType.RAISE6SEC, OfferSide.GEN, single("o", PiecewiseStepData([0.0, 5.0], [20.0])))
        @test length(get_fcas_bids(get_operation_cost(gen))) == 1
        @test get_time_series_values(SingleTimeSeries, gen, "fcas_offer_RAISE6SEC") == fill(PiecewiseStepData([0.0, 5.0], [20.0]), 2)
    end

    @testset "set_fcas_service_bids! leaves operation costs unchanged" begin
        sys = first(nem_network(db))
        set_fcas_bids!(sys, db, date_range)
        before = Dict(get_name(d) => get_operation_cost(d) for d in get_components(Device, sys) if hasmethod(get_operation_cost, Tuple{typeof(d)}))
        set_fcas_service_bids!(sys, db, date_range)
        for d in get_components(Device, sys)
            hasmethod(get_operation_cost, Tuple{typeof(d)}) || continue
            @test !(get_operation_cost(d) isa MarketBidCost)
            @test get_operation_cost(d) isa NEMOfferCost
            @test get_operation_cost(d) === before[get_name(d)]
        end
    end

    @testset "set_fcas_service_bids! rejects a bidding device without a NEMOfferCost" begin
        sys = System(100.0)
        bus = ACBus(;
            number = 1, name = "bus", available = true, bustype = ACBusTypes.REF, angle = 0.0,
            magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1), base_voltage = 230.0,
        )
        add_component!(sys, bus)
        stock = ThermalStandard(;
            name = "stock", available = true, status = true, bus, active_power = 0.0, reactive_power = 0.0, rating = 1.0,
            active_power_limits = (min = 0.0, max = 1.0), reactive_power_limits = nothing, ramp_limits = nothing,
            operation_cost = ThermalGenerationCost(; variable = CostCurve(LinearCurve(0.0)), fixed = 0.0, start_up = 0.0, shut_down = 0.0),
            base_power = 100.0, time_limits = nothing, must_run = false, prime_mover_type = PrimeMovers.ST, fuel = ThermalFuels.COAL,
        )
        add_component!(sys, stock)
        add_service!(sys, FCASService(; name = "svc", region = "NSW1", bid_type = BidType.RAISE6SEC), [stock])
        curves = [PiecewiseStepData([0.0, 5.0], [10.0])]
        @test_throws r"bidding devices must be NEM device types" AustralianElectricityMarkets._write_fcas_service_bid!(
            sys, stock, BidType.RAISE6SEC, false, curves, start_date, Minute(5),
        )
    end

    @testset "offer curves are named device series" begin
        sys = first(nem_network(db))
        added, _ = set_fcas_bids!(sys, db, date_range)
        @test !isempty(added)
        set_market_bids!(sys, db, date_range)
        set_fcas_service_bids!(sys, db, date_range)
        bids = read_fcas_bids(db, date_range, BidType.RAISE6SEC)
        gdf_inc, gdf_dec = AustralianElectricityMarkets._fcas_bid_groups(bids, get_base_power(sys))
        bidders = Iterators.flatten((get_components(Generator, sys), get_components(NEMStorage, sys), get_components(NEMLoad, sys)))
        n_checked = 0
        for device in bidders
            isempty(AustralianElectricityMarkets._fcas_services(device, BidType.RAISE6SEC)) && continue
            svc = fcas_service(device, BidType.RAISE6SEC)
            for (decremental, gdf) in ((false, gdf_inc), (true, gdf_dec))
                (isnothing(gdf) || !haskey(gdf, (get_name(device),))) && continue
                name = fcas_offer_series_name(svc, decremental)
                @test name == "fcas_offer_RAISE6SEC" * (decremental ? "_decremental" : "")
                expected = gdf[(get_name(device),)].curve_data
                stored = get_time_series_values(SingleTimeSeries, device, name)
                @test length(stored) == length(expected)
                for (s, e) in zip(stored, expected)
                    @test get_x_coords(s) == get_x_coords(e) && get_y_coords(s) == get_y_coords(e)
                end
                n_checked += 1
            end
        end
        @test n_checked > 0
    end


    @testset "set_fcas_effective_offers! skips an unavailable unpriced device, not an available one" begin
        sys = first(nem_network(db))
        set_fcas_bids!(sys, db, date_range)
        set_market_bids!(sys, db, date_range)
        set_fcas_service_bids!(sys, db, date_range)
        gen = first(g for g in get_components(Generator, sys) if has_time_series(g, SingleTimeSeries, "fcas_trapezium_RAISE6SEC"))
        # Drop the generator's offer curve to model a data gap in an available device.
        remove_time_series!(sys, SingleTimeSeries, gen, fcas_offer_series_name(fcas_service(gen, BidType.RAISE6SEC), false))
        @test get_available(gen)
        # Available devices without their curve are a real data gap, so the derivation still throws.
        @test_throws ArgumentError set_fcas_effective_offers!(sys)
        # Each contributing offer lacking its curve, found by the same rule the derivation uses.
        unpriced = Set{String}()
        for svc in get_components(FCASService, sys), device in get_contributing_devices(sys, svc)
            bid_type = get_bid_type(svc)
            for dec in AustralianElectricityMarkets.fcas_offer_sides(AustralianElectricityMarkets.fcas_bid_direction(device, bid_type))
                has_time_series(device, SingleTimeSeries, fcas_offer_series_name(svc, dec)) || push!(unpriced, get_name(device))
            end
        end
        @test get_name(gen) in unpriced
        for name in unpriced
            device = first(d for d in get_components(Device, sys) if get_name(d) == name)
            set_available!(device, false)
        end
        set_fcas_effective_offers!(sys)
        @test !has_time_series(gen, SingleTimeSeries, fcas_effective_series_name(BidType.RAISE6SEC, false))
    end

    @testset "a non-scheduled load offering FCAS joins its region's services" begin
        sys = first(nem_network(db))
        added, excluded = set_fcas_bids!(sys, db, date_range)
        asload1 = get_component(NEMLoad, sys, "ASLOAD1")
        @test "NSW1_RAISE6SEC" in added
        svc = get_component(FCASService, sys, "NSW1_RAISE6SEC")
        @test has_service(asload1, svc)
        other_loads = filter(l -> get_name(l) != "ASLOAD1", collect(get_components(NEMLoad, sys)))
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
        set_fcas_bids!(sys, db, date_range)
        @test any(
            g -> has_time_series(g, SingleTimeSeries, "fcas_trapezium_RAISE1SEC"), get_components(Generator, sys),
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
