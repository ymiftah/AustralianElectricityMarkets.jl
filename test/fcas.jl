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
        curve = make_market_bid_curve(PiecewiseStepData([0.0, 5.0, 10.0], [50.0, 60.0]), 0.0)
        trapezium = FCASTrapezium(;
            enablement_min = 20.0, low_breakpoint = 30.0, high_breakpoint = 90.0,
            enablement_max = 100.0, max_avail = 10.0,
        )
        bid = FCASBid(BidType.RAISE6SEC, curve, trapezium)
        @test get_service(bid) == BidType.RAISE6SEC
        @test get_offer_curve(bid) === curve
        @test get_trapezium(bid) === trapezium
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
            @test first(trap_rows)[1] == 20.0
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

    @testset "ConstrainedNetworkConfiguration" begin
        required_tables = table_requirements(ConstrainedNetworkConfiguration())
        @test :DISPATCH_FCAS_REQ in required_tables
        @test :DISPATCH_FCAS_REQ_CONSTRAINT in required_tables
        @test :DISPATCHCONSTRAINT in required_tables
        @test :GENCONDATA in required_tables
        @test :DISPATCHLOAD in required_tables
        @test :BIDPEROFFER_D in required_tables
        @test :SPDCONNECTIONPOINTCONSTRAINT in required_tables
        @test :SPDREGIONCONSTRAINT in required_tables
        @test :SPDINTERCONNECTORCONSTRAINT in required_tables

        sys = nem_system(db, ConstrainedNetworkConfiguration(); date_range = date_range)
        @test !isempty(collect(get_components(GenericConstraint, sys)))
        found = false
        for gen in get_components(Generator, sys)
            # has_time_series (not get_time_series + isnothing): get_time_series throws
            # ArgumentError, rather than returning nothing, for an owner with no metadata
            # registered at all - confirmed directly, same as "set_fcas_bids!" above. Series
            # name is "fcas_curve_<SERVICE>" per set_fcas_bids!, not "fcas_bid_<SERVICE>".
            has_time_series(gen, Deterministic, "fcas_curve_RAISE6SEC") || continue
            found = true
        end
        @test found
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
            @test first(trap_rows)[1] == 20.0
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
