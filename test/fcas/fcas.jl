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

    @testset "FCASBid construction" begin
        curve = PiecewiseStepData([0.0, 5.0, 10.0], [50.0, 60.0])
        trapezium = FCASTrapezium(;
            enablement_min = 20.0, low_breakpoint = 30.0, high_breakpoint = 90.0,
            enablement_max = 100.0, max_avail = 10.0,
        )
        bid = FCASBid(BidType.RAISE6SEC, curve, trapezium)
        @test get_service(bid) == BidType.RAISE6SEC
        @test get_offer_curve(bid) === curve
        @test get_offer_curve(bid) isa PiecewiseStepData
        @test get_trapezium(bid) === trapezium
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
        back_no_ramps = FCASTrapezium(nt)
        @test back_no_ramps.enablement_min == no_ramps.enablement_min
        @test back_no_ramps.low_breakpoint == no_ramps.low_breakpoint
        @test back_no_ramps.high_breakpoint == no_ramps.high_breakpoint
        @test back_no_ramps.enablement_max == no_ramps.enablement_max
        @test back_no_ramps.max_avail == no_ramps.max_avail
        @test isnothing(back_no_ramps.ramp_up_rate)
        @test isnothing(back_no_ramps.ramp_down_rate)
        @test isequal(back_no_ramps, no_ramps)
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

    @testset "get_fcas_trapezium/get_fcas_offer_curve/get_fcas_bid" begin
        sys = nem_system(db, RegionalNetworkConfiguration())
        set_fcas_bids!(sys, db, date_range)
        bw01 = get_component(EnergyReservoirStorage, sys, "BW01")
        horizon = length(date_range) - 1

        trapeziums = get_fcas_trapezium(bw01, BidType.RAISE6SEC, start_date, horizon)
        curves = get_fcas_offer_curve(bw01, BidType.RAISE6SEC, start_date, horizon)
        bids = get_fcas_bid(bw01, BidType.RAISE6SEC, start_date, horizon)
        @test trapeziums isa Vector{FCASTrapezium}
        @test curves isa Vector{PiecewiseStepData}
        @test bids isa Vector{FCASBid}
        @test length(trapeziums) == length(curves) == length(bids) == horizon
        @test all(get_trapezium(b) == trapeziums[i] for (i, b) in enumerate(bids))
        @test all(get_offer_curve(b) == curves[i] for (i, b) in enumerate(bids))

        # decremental = true reads a genuinely separate series: it succeeds for BW01 (which
        # has both directions attached) but throws for a Generator (incremental-only), proving
        # it isn't just re-reading the incremental series under a different name.
        dec_trapeziums = get_fcas_trapezium(bw01, BidType.RAISE6SEC, start_date, horizon; decremental = true)
        @test dec_trapeziums isa Vector{FCASTrapezium}
        @test length(dec_trapeziums) == horizon
        @test_throws ArgumentError get_fcas_trapezium(
            first(get_components(Generator, sys)), BidType.RAISE6SEC, start_date, horizon; decremental = true,
        )

        # A component with no FCAS series attached at all throws, naming what's missing.
        no_bids_sys = nem_system(db, RegionalNetworkConfiguration())
        no_bids_gen = first(get_components(Generator, no_bids_sys))
        err = try
            get_fcas_trapezium(no_bids_gen, BidType.RAISE6SEC, start_date, horizon)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("RAISE6SEC", err.msg)
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
        @test all(==(20.0), bids.ENABLEMENTMIN)
        @test all(==(100.0), bids.ENABLEMENTMAX)
        @test "piecewise_step_data" in names(bids)

        reg_bids = read_fcas_bids(db, date_range, BidType.RAISEREG)
        @test !isempty(reg_bids)
        @test all(==(1.0), reg_bids.ROCUP)
    end

    @testset "set_fcas_bids!" begin
        # Two Deterministic series per (component, market), not a Reserve/service and not a
        # single-object FCASBid series: confirmed directly that Deterministic rejects
        # FCASBid/bare Vector{Float64} as a per-step element type (see "FCASBid time series
        # round-trip" below).
        sys = nem_system(db, RegionalNetworkConfiguration())
        set_fcas_bids!(sys, db, date_range)
        base_power = get_base_power(sys)

        found = false
        for gen in get_components(Generator, sys)
            # has_time_series (not get_time_series + isnothing): get_time_series throws
            # ArgumentError, rather than returning nothing, for an owner with no metadata
            # registered at all for (Deterministic, name) - confirmed directly.
            has_time_series(gen, Deterministic, "fcas_curve_RAISE6SEC") || continue
            found = true
            curve_ts = get_time_series(Deterministic, gen, "fcas_curve_RAISE6SEC")
            trapezium_ts = get_time_series(Deterministic, gen, "fcas_trapezium_RAISE6SEC")
            @test !isnothing(curve_ts)
            @test !isnothing(trapezium_ts)
            trap_rows = first(values(get_data(trapezium_ts)))
            # Raw stored series is per-unit of sys's base power - get_fcas_trapezium (tested
            # above) is what converts back to MW.
            @test first(trap_rows)[1] == 20.0 / base_power
        end
        @test found

        # BW01's LOAD-direction FCAS bids attach to its EnergyReservoirStorage component
        # under the "_decremental" suffix, not dropped like an earlier version of
        # set_fcas_bids! dropped every non-GEN DIRECTION row.
        bw01 = get_component(EnergyReservoirStorage, sys, "BW01")
        @test !isnothing(bw01)
        @test has_time_series(bw01, Deterministic, "fcas_curve_RAISE6SEC_decremental")
        @test has_time_series(bw01, Deterministic, "fcas_trapezium_RAISE6SEC_decremental")
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
        set_fcas_bids!(sys, db, date_range)
        base_power = get_base_power(sys)

        mktpath = mktempdir()
        json_path = joinpath(mktpath, "sys.json")
        to_json(sys, json_path)
        sys2 = System(json_path)

        found = false
        for gen in get_components(Generator, sys2)
            has_time_series(gen, Deterministic, "fcas_curve_RAISE6SEC") || continue
            found = true
            curve_ts = get_time_series(Deterministic, gen, "fcas_curve_RAISE6SEC")
            trapezium_ts = get_time_series(Deterministic, gen, "fcas_trapezium_RAISE6SEC")
            @test !isnothing(curve_ts)
            @test !isnothing(trapezium_ts)
            trap_rows = first(values(get_data(trapezium_ts)))
            @test first(trap_rows)[1] == 20.0 / base_power
        end
        @test found
    end

    @testset "FCASBid time series round-trip" begin
        # Deterministic rejects FCASBid and bare Vector{Float64} as per-step element types;
        # use NTuple{7,Float64} (see task-4-report.md).
        sys = System(100.0)
        bus = ACBus(; number = 1, name = "b1", available = true, bustype = ACBusTypes.REF, angle = 0.0, magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1), base_voltage = 130.0)
        add_component!(sys, bus)
        gen = ThermalStandard(;
            name = "G1", available = true, status = true, bus = bus,
            active_power = 0.0, reactive_power = 0.0, rating = 1.0,
            active_power_limits = (min = 0.0, max = 1.0), reactive_power_limits = nothing,
            ramp_limits = nothing,
            operation_cost = ThermalGenerationCost(;
                variable = CostCurve(LinearCurve(0.0)), fixed = 0.0, start_up = 0.0, shut_down = 0.0,
            ),
            base_power = 100.0, time_limits = nothing, must_run = false,
            prime_mover_type = PrimeMovers.ST, fuel = ThermalFuels.COAL,
        )
        add_component!(sys, gen)

        psd = PiecewiseStepData([0.0, 5.0], [50.0])
        trapezium = FCASTrapezium(; enablement_min = 20.0, low_breakpoint = 30.0, high_breakpoint = 90.0, enablement_max = 100.0, max_avail = 10.0)
        trap_row = (
            get_enablement_min(trapezium), get_low_breakpoint(trapezium), get_high_breakpoint(trapezium),
            get_enablement_max(trapezium), get_max_avail(trapezium),
            something(get_ramp_up_rate(trapezium), NaN), something(get_ramp_down_rate(trapezium), NaN),
        )

        start_date = DateTime(2025, 1, 1)
        curve_ts = Deterministic(;
            name = "fcas_curve_RAISE6SEC", data = Dict(start_date => [psd, psd]),
            resolution = Minute(5), interval = Minute(5),
        )
        add_time_series!(sys, gen, curve_ts)
        trapezium_ts = Deterministic(;
            name = "fcas_trapezium_RAISE6SEC", data = Dict(start_date => [trap_row, trap_row]),
            resolution = Minute(5), interval = Minute(5),
        )
        add_time_series!(sys, gen, trapezium_ts)

        mktpath = mktempdir()
        json_path = joinpath(mktpath, "sys.json")
        to_json(sys, json_path)
        sys2 = System(json_path)
        gen2 = get_component(ThermalStandard, sys2, "G1")

        curve_ts2 = get_time_series(Deterministic, gen2, "fcas_curve_RAISE6SEC")
        trapezium_ts2 = get_time_series(Deterministic, gen2, "fcas_trapezium_RAISE6SEC")
        @test !isnothing(curve_ts2)
        @test !isnothing(trapezium_ts2)

        curve_data2 = only(values(get_data(curve_ts2)))
        @test curve_data2 isa Vector{PiecewiseStepData}
        @test length(curve_data2) == 2
        @test get_x_coords(curve_data2[1]) == [0.0, 5.0]
        @test get_y_coords(curve_data2[1]) == [50.0]

        trapezium_data2 = only(values(get_data(trapezium_ts2)))
        @test length(trapezium_data2) == 2
        row2 = trapezium_data2[1]
        @test collect(row2[1:5]) == [20.0, 30.0, 90.0, 100.0, 10.0]
        @test isnan(row2[6])
        @test isnan(row2[7])
    end
end
