# Effective FCAS offers and tie-break scales, derived by `set_effective_offers!` (run by `prepare_replay!`),
# and the accessors that read the derived inputs.

@testset "Effective offers" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))

    @testset "derived offers equal the values attached before the bids were split out" begin
        replay_db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
        interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
        sys = nem_system(replay_db, NEMDEConfiguration(); date_range = interval)
        set_effective_offers!(sys)
        values_of(device, name) = get_time_series_values(SingleTimeSeries, device, name; ignore_scaling_factors = true)
        er01 = get_component(NEMThermalGen, sys, "ER01")
        bw01 = get_component(NEMStorage, sys, "BW01")
        asload1 = get_component(NEMLoad, sys, "ASLOAD1")
        prices_ascending = [51.0, 52.0, 53.0, 54.0, 55.0, 56.0, 57.0, 58.0, 59.0, 60.0]
        prices_descending = reverse(prices_ascending)
        bands = [0.0, 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0]

        @test PowerSystems.get_x_coords(first(values_of(er01, "energy_offer"))) == bands
        @test PowerSystems.get_y_coords(first(values_of(er01, "energy_offer"))) == prices_ascending
        @test first(values_of(er01, "energy_max_avail")) ≈ 1.01
        @test PowerSystems.get_y_coords(first(values_of(bw01, "energy_offer_decremental"))) == prices_descending
        @test first(values_of(bw01, "energy_max_avail_decremental")) ≈ 1.01
        @test PowerSystems.get_y_coords(first(values_of(bw01, "fcas_offer_RAISEREG"))) == prices_ascending
        @test isequal(collect(first(values_of(bw01, "fcas_trapezium_RAISEREG"))), [0.2, 0.3, 0.9, 1.0, 0.21, NaN, NaN])
        @test PowerSystems.get_y_coords(first(values_of(asload1, "fcas_offer_RAISE6SEC_decremental"))) == prices_descending
    end

    @testset "get_fcas_offer reads the scaled trapezium and the offer curve" begin
        sys = first(nem_network(db))
        set_market_bids!(sys, db, date_range)
        set_effective_offers!(sys)
        horizon = length(date_range) - 1
        # ASLOAD1 is a zero-cost non-scheduled load, so its decremental offer is read from its own series.
        asload1 = get_component(NEMLoad, sys, "ASLOAD1")
        curves = AustralianElectricityMarkets._get_fcas_offer_curve(asload1, BidType.RAISE6SEC, start_date, horizon; decremental = true)
        offer = get_fcas_offer(asload1, BidType.RAISE6SEC, OfferSide.LOAD, start_date, horizon)
        @test offer isa NEMFCASOffer && offer.service == BidType.RAISE6SEC && offer.side == OfferSide.LOAD
        @test offer.trapeziums == get_scaled_fcas_trapezium(asload1, BidType.RAISE6SEC, start_date, horizon; decremental = true)
        @test offer.curves == curves
    end

    @testset "set_effective_offers! output survives a JSON round-trip" begin
        sys = System(100.0)
        area = Area(; name = "NSW")
        add_component!(sys, area)
        bus = ACBus(; number = 1, name = "b1", available = true, bustype = ACBusTypes.REF, angle = 0.0, magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1), base_voltage = 130.0)
        add_component!(sys, bus)
        set_area!(bus, area)
        start = DateTime(2025, 1, 1)
        # Both units have a price-10 band and a price-20 band; the widths differ at price 10 (5 vs 2) and at 20 (10 vs 13).
        curves = Dict("G1" => PiecewiseStepData([0.0, 5.0, 15.0], [10.0, 20.0]), "G2" => PiecewiseStepData([0.0, 2.0, 15.0], [10.0, 20.0]))
        for (name, curve) in curves
            gen = NEMThermalGen(;
                name = name, available = true, status = true, bus = bus,
                active_power = 0.0, reactive_power = 0.0, rating = 1.0,
                active_power_limits = (min = 0.0, max = 1.0), reactive_power_limits = nothing,
                ramp_limits = nothing,
                operation_cost = NEMOfferCost(),
                base_power = 100.0, time_limits = nothing, must_run = false,
                prime_mover_type = PrimeMovers.ST, fuel = ThermalFuels.COAL,
            )
            add_component!(sys, gen)
            _toy_energy_bid!(sys, gen, AustralianElectricityMarkets.BidDirection.GEN, [start, start + Minute(5)], fill(curve, 2), fill(PSY.get_base_power(sys), 2))
        end

        set_effective_offers!(sys)
        g1, g2 = get_component(NEMThermalGen, sys, "G1"), get_component(NEMThermalGen, sys, "G2")
        @test get_time_series_values(SingleTimeSeries, g1, "tie_break_scale_1") ≈ [1.0, 1.0]
        @test get_time_series_values(SingleTimeSeries, g2, "tie_break_scale_1") ≈ [0.4, 0.4]
        @test get_time_series_values(SingleTimeSeries, g1, "tie_break_scale_2") ≈ [10.0 / 13.0, 10.0 / 13.0]
        @test get_time_series_values(SingleTimeSeries, g2, "tie_break_scale_2") ≈ [1.0, 1.0]

        json_path = joinpath(mktempdir(), "sys.json")
        to_json(sys, json_path)
        sys2 = System(json_path)

        service = get_component(EnergyTieBreak, sys2, "energy_tie_break")
        @test sort!(get_name.(get_contributing_devices(sys2, service))) == ["G1", "G2"]
        @test get_time_series_values(SingleTimeSeries, get_component(NEMThermalGen, sys2, "G2"), "tie_break_scale_1") ≈ [0.4, 0.4]
        @test get_time_series_values(SingleTimeSeries, get_component(NEMThermalGen, sys2, "G1"), "tie_break_scale_2") ≈ [10.0 / 13.0, 10.0 / 13.0]
    end

    @testset "energy prices are referred by the factor of their own side, and inputs are validated" begin
        start = DateTime(2025, 1, 1)
        stamps = [start, start + Minute(5)]
        # One bus with a generator (GEN bid) and a scheduled load (LOAD bid), and a generator with no energy bid.
        function unit_system()
            sys = System(100.0)
            area = Area(; name = "NSW")
            add_component!(sys, area)
            bus = ACBus(; number = 1, name = "b1", available = true, bustype = ACBusTypes.REF, angle = 0.0, magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1), base_voltage = 130.0)
            add_component!(sys, bus)
            set_area!(bus, area)
            for name in ("GEN1", "GEN2")
                add_component!(
                    sys, NEMThermalGen(;
                        name = name, available = true, status = true, bus = bus,
                        active_power = 0.0, reactive_power = 0.0, rating = 1.0,
                        active_power_limits = (min = 0.0, max = 1.0), reactive_power_limits = nothing,
                        ramp_limits = nothing, operation_cost = NEMOfferCost(), base_power = 100.0, time_limits = nothing,
                        must_run = false, prime_mover_type = PrimeMovers.ST, fuel = ThermalFuels.COAL,
                    ),
                )
            end
            add_component!(
                sys, NEMLoad(;
                    name = "PUMP2", available = true, bus = bus, active_power = 0.0, reactive_power = 0.0,
                    max_active_power = 1.0, max_reactive_power = 0.0, base_power = 100.0, operation_cost = NEMOfferCost(),
                ),
            )
            return sys
        end

        @testset "GEN and LOAD prices use their own loss factor" begin
            sys = unit_system()
            gen = get_component(NEMThermalGen, sys, "GEN1")
            load = get_component(NEMLoad, sys, "PUMP2")
            gen_curve = PiecewiseStepData([0.0, 10.0, 20.0], [41.0, 57.0])
            load_curve = PiecewiseStepData([0.0, 10.0, 20.0], [33.0, 61.0])
            _toy_energy_bid!(sys, gen, AustralianElectricityMarkets.BidDirection.GEN, stamps, fill(gen_curve, 2), fill(100.0, 2))
            _toy_energy_bid!(sys, load, AustralianElectricityMarkets.BidDirection.LOAD, stamps, fill(load_curve, 2), fill(100.0, 2))
            gen_lf, load_lf = 0.9 * 0.97, 0.8
            for device in (gen, load)
                set_registration!(device, _toy_registration(; gen_loss_factor = gen_lf, load_loss_factor = load_lf))
            end
            set_effective_offers!(sys)
            lf_values(device, name) = get_time_series_values(SingleTimeSeries, device, name; ignore_scaling_factors = true)
            bid_prices(device, direction) = get_y_coords(first(lf_values(device, bid_series_name(BidType.ENERGY, :offer_curves, direction))))
            @test get_y_coords(first(lf_values(gen, "energy_offer"))) == round.(bid_prices(gen, AustralianElectricityMarkets.BidDirection.GEN) ./ gen_lf; digits = 2)
            @test get_y_coords(first(lf_values(load, "energy_offer_decremental"))) == round.(bid_prices(load, AustralianElectricityMarkets.BidDirection.LOAD) ./ load_lf; digits = 2)
            @test get_y_coords(first(lf_values(gen, "energy_offer"))) != round.(get_y_coords(gen_curve) ./ load_lf; digits = 2)
        end

        @testset "a static energy bid is rejected, as it has no series to derive from" begin
            sys = unit_system()
            gen = get_component(NEMThermalGen, sys, "GEN1")
            set_operation_cost!(
                gen,
                NEMOfferCost(;
                    energy = [
                        NEMEnergyBid(;
                            direction = AustralianElectricityMarkets.BidDirection.GEN,
                            offer_curves = PiecewiseStepData([0.0, 10.0], [5.0]), max_avail = 10.0, roc_up = 0.0, roc_down = 0.0,
                        ),
                    ],
                ),
            )
            @test_throws ArgumentError set_effective_offers!(sys)
        end

        @testset "two FCAS bids of one service on one side are rejected" begin
            sys = unit_system()
            gen = get_component(NEMThermalGen, sys, "GEN2")
            for direction in (AustralianElectricityMarkets.BidDirection.GEN, AustralianElectricityMarkets.BidDirection.BIDIRECTIONAL)
                name(f) = bid_series_name(BidType.RAISE6SEC, f, direction)
                replace_single_series_with!(sys, gen, name(:offer_curves), fill(PiecewiseStepData([0.0, 10.0], [5.0]), 2), stamps)
                replace_single_series_with!(sys, gen, name(:max_avail), fill(10.0, 2), stamps)
                replace_single_series_with!(sys, gen, name(:trapezium), fill((0.0, 10.0, 90.0, 100.0), 2), stamps)
                AustralianElectricityMarkets._set_fcas_bid!(
                    get_operation_cost(gen),
                    AustralianElectricityMarkets.NEMFCASBid(;
                        service = BidType.RAISE6SEC, direction,
                        offer_curves = AustralianElectricityMarkets._series_key(gen, name(:offer_curves)),
                        max_avail = AustralianElectricityMarkets._series_key(gen, name(:max_avail)),
                        trapezium = AustralianElectricityMarkets._series_key(gen, name(:trapezium)),
                    ),
                )
            end
            @test_throws ArgumentError set_effective_offers!(sys)
        end
    end

    @testset "NEMDE replay attaches FCAS effective offers and tie-break scales" begin
        replay_db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
        interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
        sys = nem_system(replay_db, NEMDEConfiguration(); date_range = interval)
        set_effective_offers!(sys)
        series = [
            get_name(key) for device in get_components(StaticInjection, sys)
                for key in PowerSystems.get_time_series_keys(device)
        ]
        @test any(startswith(name, "fcas_effective_") for name in series)
        # The mock's energy bands are never tied across units within an interval, so no tie-break scale is written;
        # the EnergyTieBreak service below still records that set_effective_offers! ran.
        @test !any(startswith(name, "tie_break_scale_") for name in series)
        service = get_component(EnergyTieBreak, sys, TIE_BREAK_SERVICE_NAME)
        @test !isnothing(service)
        @test !isempty(get_contributing_devices(sys, service))
    end

    @testset "a unit registered mid-chunk offers no FCAS where its padded stamps are" begin
        interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
        # A unit first registered at `stamp`: its summary and loss-factor rows start there, and its
        # bids and dispatch rows before it are removed, as NEMWEB has them.
        function registered_from(source, duid, stamp)
            t = "TIMESTAMP '$stamp'"
            steps = [
                (:DUDETAILSUMMARY, "UPDATE input SET START_DATE = $t WHERE DUID = '$duid'"),
                (:DUDETAIL, "UPDATE input SET EFFECTIVEDATE = $t WHERE DUID = '$duid'"),
                (:BIDPEROFFER_D, "DELETE FROM input WHERE DUID = '$duid' AND INTERVAL_DATETIME <= $t"),
                (:DISPATCHLOAD, "DELETE FROM input WHERE DUID = '$duid' AND SETTLEMENTDATE <= $t"),
            ]
            for (table, query) in steps
                source = damaged_cache(source, table, query).config.hive_location
            end
            return source
        end
        late_hive = registered_from(AEM_TEST_REPLAY_HIVE_DIR, "BW02", "2025-01-01 00:10:00")
        late = nem_system(
            aem_connect(HiveConfiguration(hive_location = late_hive, filesystem = "file")), NEMDEConfiguration(); date_range = interval,
        )
        set_effective_offers!(late)
        bw02 = get_component(Generator, late, "BW02")
        # BW02's RAISE6SEC is a modelled incremental bid, so its effective offer is disabled where AEMO publishes none.
        raise6 = BidType.RAISE6SEC
        inactive = -FCAS_INACTIVE_LIMIT_MW / get_base_power(late)
        effective = get_time_series_values(SingleTimeSeries, bw02, fcas_effective_series_name(raise6, false); ignore_scaling_factors = true)
        for i in 1:2
            @test effective[i][1] == 0.0
            @test effective[i][2] == inactive
        end
        # A tie-break scale is zero where the padded band has no width, or absent when the unit is never tied.
        for key in get_time_series_keys(bw02)
            get_time_series_type(key) === SingleTimeSeries && startswith(get_name(key), "tie_break_scale_") || continue
            values = get_time_series_values(SingleTimeSeries, bw02, get_name(key); ignore_scaling_factors = true)
            @test all(iszero, values[1:2])
        end
    end
end

@testset "FCAS scaling accessors" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    hive_dir = AEM_TEST_HIVE_DIR
    sys_base, _ = nem_network(db)
    resolution = Minute(5)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:resolution:(start_date + Hour(2))
    base_power = get_base_power(sys_base)
    truth = read_unit_conditions(db, date_range)

    @testset "load regulation scaling uses consumption ramp direction" begin
        rates_db = damaged_cache(
            hive_dir, :DISPATCHLOAD,
            "UPDATE input SET RAMPUPRATE = 120, RAMPDOWNRATE = 60, RAISEREGENABLEMENTMIN = 0, RAISEREGENABLEMENTMAX = 0, LOWERREGENABLEMENTMIN = 0, LOWERREGENABLEMENTMAX = 0 WHERE DUID = 'PUMP1'",
        )
        sys = deepcopy(sys_base)
        load = get_component(NEMLoad, sys, "PUMP1")
        horizon = length(date_range) - 1
        trap = (0.0, 10.0, 90.0, 100.0, 20.0, NaN, NaN) ./ base_power
        for service in (BidType.RAISEREG, BidType.LOWERREG)
            add_time_series!(sys, load, single_series(fcas_series_name("fcas_trapezium", service, OfferSide.LOAD), start_date, fill(trap, horizon), resolution))
        end
        set_unit_conditions!(sys, rates_db, date_range)
        AustralianElectricityMarketsSimulations._set_dispatch_limits!(sys)
        with_units_base(sys, "NATURAL_UNITS") do
            raise = get_scaled_fcas_trapezium(load, BidType.RAISEREG, start_date, horizon; decremental = true)
            lower = get_scaled_fcas_trapezium(load, BidType.LOWERREG, start_date, horizon; decremental = true)
            @test get_max_avail.(raise) ≈ fill(5.0, horizon)
            @test get_max_avail.(lower) ≈ fill(10.0, horizon)
            raw = AustralianElectricityMarkets._get_fcas_trapezium(load, BidType.RAISEREG, start_date, horizon; decremental = true)
            @test get_max_avail.(raw) == fill(20.0, horizon)
        end
    end

    @testset "load regulation availability pairs with its own service" begin
        rates_db = damaged_cache(
            hive_dir, :DISPATCHLOAD,
            "UPDATE input SET RAMPUPRATE = 180, RAMPDOWNRATE = 720, RAISEREGAVAILABILITY = 0, LOWERREGAVAILABILITY = 60, RAISEREGENABLEMENTMIN = 0, RAISEREGENABLEMENTMAX = 0, LOWERREGENABLEMENTMIN = 0, LOWERREGENABLEMENTMAX = 0 WHERE DUID = 'PUMP1'",
        )
        sys = deepcopy(sys_base)
        load = get_component(NEMLoad, sys, "PUMP1")
        horizon = length(date_range) - 1
        trap = (0.0, 10.0, 90.0, 100.0, 100.0, NaN, NaN) ./ base_power
        for service in (BidType.RAISEREG, BidType.LOWERREG)
            add_time_series!(sys, load, single_series(fcas_series_name("fcas_trapezium", service, OfferSide.LOAD), start_date, fill(trap, horizon), resolution))
        end
        set_unit_conditions!(sys, rates_db, date_range)
        AustralianElectricityMarketsSimulations._set_dispatch_limits!(sys)
        with_units_base(sys, "NATURAL_UNITS") do
            # 60 MW per 5 minutes is LOWERREGAVAILABILITY; the up ramp rate alone would give 15.
            lower = get_scaled_fcas_trapezium(load, BidType.LOWERREG, start_date, horizon; decremental = true)
            raise = get_scaled_fcas_trapezium(load, BidType.RAISEREG, start_date, horizon; decremental = true)
            @test get_max_avail.(lower) ≈ fill(60.0, horizon)
            @test get_max_avail.(raise) ≈ fill(60.0, horizon)
        end
    end

    @testset "get_scaled_fcas_trapezium skips scaling only at an absent interval" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_unit_conditions!(sys, db, date_range)
        set_effective_offers!(sys)

        device = get_component(NEMThermalGen, sys, "ER01")
        full_grid = collect(date_range)[1:(end - 1)]
        horizon = length(full_grid)
        # 60 MW/h is a 5 MW AGC ramping capability over 5 minutes.
        ramp = [t == first(full_grid) ? NaN : 60.0 / 60 / base_power for t in full_grid]
        replace_single_series!(sys, device, single_series(AustralianElectricityMarkets.NEM_SERIES.dispatch_ramp_up_rate, full_grid, ramp))
        AustralianElectricityMarketsSimulations._set_dispatch_limits!(sys)

        raw, scaled = with_units_base(sys, "NATURAL_UNITS") do
            (
                AustralianElectricityMarkets._get_fcas_trapezium(device, BidType.RAISEREG, start_date, horizon),
                get_scaled_fcas_trapezium(device, BidType.RAISEREG, start_date, horizon),
            )
        end
        @test get_max_avail(raw[1]) > 5.0
        # Without a ramp rate at an interval, the ramp limit there is zero, as HEAD.
        @test get_time_series_values(SingleTimeSeries, device, "ramp_up_rate")[1] == 0.0
        @test isequal(get_max_avail(scaled[1]), get_max_avail(raw[1]))
        @test all(i -> isapprox(get_max_avail(scaled[i]), min(get_max_avail(raw[i]), 5.0)), 2:horizon)
    end

    @testset "get_scaled_fcas_trapezium narrows the trapezium wherever the AGC input is more restrictive" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_effective_offers!(sys)
        set_unit_conditions!(sys, db, date_range)
        AustralianElectricityMarketsSimulations._set_dispatch_limits!(sys)

        device = get_component(NEMThermalGen, sys, "ER01")
        initial_time = start_date
        horizon = length(date_range) - 1

        raw = AustralianElectricityMarkets._get_fcas_trapezium(device, BidType.RAISEREG, initial_time, horizon)
        scaled = get_scaled_fcas_trapezium(device, BidType.RAISEREG, initial_time, horizon)
        @test length(raw) == horizon

        for i in 1:horizon
            @test get_max_avail(scaled[i]) <= get_max_avail(raw[i])
            @test get_enablement_min(scaled[i]) >= get_enablement_min(raw[i])
            @test get_enablement_max(scaled[i]) <= get_enablement_max(raw[i])
        end
        @test any(i -> get_max_avail(scaled[i]) < get_max_avail(raw[i]), 1:horizon)

        # The AGC ramping capability is the MW/h ramp rate times the interval length.
        rows = sort(subset(truth, :DUID => ByRow(==("ER01"))), :SETTLEMENTDATE)
        for (resolution_i, hours) in ((Minute(5), 5 / 60), (Minute(30), 0.5))
            scaled_i = with_units_base(sys, "NATURAL_UNITS") do
                get_scaled_fcas_trapezium(
                    device, BidType.RAISEREG, initial_time, horizon; resolution = resolution_i,
                )
            end
            raw_mw = with_units_base(() -> get_max_avail.(AustralianElectricityMarkets._get_fcas_trapezium(device, BidType.RAISEREG, initial_time, horizon)), sys, "NATURAL_UNITS")
            @test isapprox(
                get_max_avail.(scaled_i),
                min.(raw_mw, max.(rows.RAMPUPRATE, rows.RAISEREGAVAILABILITY .* 12) .* hours); atol = 1.0e-6,
            )
        end

        # A contingency market carries no AGC scaling input series at all: unscaled.
        raw_contingency = AustralianElectricityMarkets._get_fcas_trapezium(device, BidType.RAISE6SEC, initial_time, horizon)
        scaled_contingency = get_scaled_fcas_trapezium(device, BidType.RAISE6SEC, initial_time, horizon)
        @test all(i -> isequal(Tuple(raw_contingency[i]), Tuple(scaled_contingency[i])), 1:horizon)
    end
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
        AEMS._require_equal_length(trapeziums, curves, BidType.RAISE6SEC, mock_bus)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("RAISE6SEC", err.msg)
    @test occursin("BW01", err.msg)
end

@testset "Accessors of offers, dispatch limits and AGC status" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    sys_base, _ = nem_network(db)
    resolution = Minute(5)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:resolution:(start_date + Hour(2))
    horizon = length(date_range) - 1
    base_power = get_base_power(sys_base)
    truth = read_dispatch_limits(db, date_range)
    scaling_truth = read_unit_conditions(db, date_range)

    @testset "energy offer views and MAXAVAIL per direction" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range)
        set_effective_offers!(sys)
        for bat in get_components(NEMStorage, sys)
            gen_offer, load_offer = get_energy_offer(bat, OfferSide.GEN), get_energy_offer(bat, OfferSide.LOAD)
            ta_gen = get_time_series_array(SingleTimeSeries, bat, "energy_offer")
            ta_load = get_time_series_array(SingleTimeSeries, bat, "energy_offer_decremental")
            @test gen_offer.side == OfferSide.GEN && load_offer.side == OfferSide.LOAD
            @test gen_offer.timestamps == PowerSystems.TimeSeries.timestamp(ta_gen) && gen_offer.curves == values(ta_gen)
            @test load_offer.curves == values(ta_load)
            # Energy MAXAVAIL per direction; the mock bids 100 + i MW on both sides, rising with i.
            avail = with_units_base(sys, "NATURAL_UNITS") do
                get_storage_energy_max_avail(bat, start_date, horizon)
            end
            @test !isnothing(avail)
            @test length(avail.gen) == horizon
            @test avail.gen ≈ avail.load
            @test all(x -> 100.0 <= x <= 149.0, avail.gen)
            @test avail.gen[end] > avail.gen[1]
        end
        @test isnothing(get_storage_energy_max_avail(first(get_components(NEMThermalGen, sys)), start_date, 1))
        @test isnothing(get_energy_offer(first(get_components(PowerLoad, sys)), OfferSide.GEN))
    end

    @testset "a device that is not a NEM type has no offer view" begin
        sys = deepcopy(sys_base)
        bus = first(get_components(ACBus, sys))
        start = DateTime(2025, 1, 1)
        stock = ThermalStandard(;
            name = "stock", available = true, status = true, bus, active_power = 0.0, reactive_power = 0.0, rating = 1.0,
            active_power_limits = (min = 0.0, max = 1.0), reactive_power_limits = nothing, ramp_limits = nothing,
            operation_cost = ThermalGenerationCost(; variable = CostCurve(LinearCurve(0.0)), fixed = 0.0, start_up = 0.0, shut_down = 0.0),
            base_power = 100.0, time_limits = nothing, must_run = false, prime_mover_type = PrimeMovers.ST, fuel = ThermalFuels.COAL,
        )
        add_component!(sys, stock)
        @test isnothing(get_energy_offer(stock, OfferSide.GEN))
        @test isnothing(get_energy_offer(stock, OfferSide.LOAD))
    end

    @testset "offer views of each side after set_market_bids!" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range)
        set_effective_offers!(sys)
        gen = first(get_components(NEMThermalGen, sys))
        storage = first(get_components(NEMStorage, sys))
        for (device, side) in ((gen, OfferSide.GEN), (storage, OfferSide.GEN), (storage, OfferSide.LOAD))
            offer = get_energy_offer(device, side)
            @test offer.side == side
            @test offer.curves == get_time_series_values(SingleTimeSeries, device, energy_offer_series_name(side))
            @test offer.timestamps[1] == date_range[1]
        end
    end

    @testset "a second set_market_bids! replaces the offer timestamps" begin
        sys = deepcopy(sys_base)
        second_range = (start_date + Minute(30)):Minute(5):(start_date + Minute(90))
        set_market_bids!(sys, db, date_range)
        set_effective_offers!(sys)
        set_market_bids!(sys, db, second_range)
        set_effective_offers!(sys)
        for device in vcat(collect(get_components(NEMThermalGen, sys)), collect(get_components(NEMStorage, sys)))
            get_available(device) || continue
            for side in [AustralianElectricityMarkets._energy_offer_side(b.direction) for b in AustralianElectricityMarkets.get_energy_bids(get_operation_cost(device))]
                @test get_energy_offer(device, side).timestamps[1] == second_range[1]
            end
        end
    end

    @testset "initial_mw and availability read back as the DISPATCHLOAD columns" begin
        sys = deepcopy(sys_base)
        attach_dispatch_limits!(sys, db, date_range)
        renewable = get_component(NEMRenewableGen, sys, "BW03")
        battery = get_component(NEMStorage, sys, "BW01")
        with_units_base(sys, "NATURAL_UNITS") do
            for (device, duid) in ((renewable, "BW03"), (battery, "BW01"))
                rows = sort(subset(truth, :DUID => ByRow(==(duid))), :SETTLEMENTDATE)
                @test isapprox(get_initial_mw(device, start_date, horizon), rows.INITIALMW; atol = 1.0e-8)
            end
            rows = sort(subset(truth, :DUID => ByRow(==("BW03"))), :SETTLEMENTDATE)
            @test isapprox(get_energy_availability(renewable, start_date, horizon), rows.AVAILABILITY; atol = 1.0e-8)
        end
        # A battery's availability comes from its energy bid, not AVAILABILITY.
        @test isnothing(get_energy_availability(battery, start_date, horizon))
    end

    @testset "get_initial_mw is nothing when initial_mw is not attached" begin
        sys = deepcopy(sys_base)
        bat = get_component(NEMStorage, sys, "BW01")
        @test isnothing(get_initial_mw(bat, start_date, horizon))
    end

    @testset "get_fcas_agc_status reads back AGCSTATUS and is nothing when not attached" begin
        sys = deepcopy(sys_base)
        set_unit_conditions!(sys, db, date_range)
        AustralianElectricityMarketsSimulations._set_dispatch_limits!(sys)
        device = get_component(NEMThermalGen, sys, "ER01")
        rows = sort(subset(scaling_truth, :DUID => ByRow(==("ER01"))), :SETTLEMENTDATE)
        @test get_fcas_agc_status(device, start_date, horizon) == round.(Int, rows.AGCSTATUS)
        load = get_component(NEMLoad, sys, "PUMP1")
        @test get_fcas_agc_status(load, start_date, horizon) == ones(Int, horizon)

        bare = deepcopy(sys_base)
        @test isnothing(get_fcas_agc_status(get_component(NEMThermalGen, bare, "ER01"), start_date, horizon))
    end

    @testset "get_fcas_agc_status is nothing at an interval with no AGCSTATUS" begin
        sys = deepcopy(sys_base)
        device = get_component(NEMThermalGen, sys, "ER01")
        full_grid = collect(date_range)[1:(end - 1)]
        status = [t == first(full_grid) ? NaN : 1.0 for t in full_grid]
        replace_single_series!(sys, device, single_series(AustralianElectricityMarkets.NEM_SERIES.fcas_agc_status, full_grid, status))
        status = get_fcas_agc_status(device, start_date, length(full_grid))
        @test isnothing(status[1])
        @test all(==(1), status[2:end])
    end
end

@testset "Initial-state dispatch limits" begin
    AEMSim = AustralianElectricityMarketsSimulations
    @testset "_max_active_power is the availability unless the ramp-down floor is higher" begin
        @test AEMSim._max_active_power(100.0, 50.0, 40.0, 1 / 12) == 100.0
        @test AEMSim._max_active_power(10.0, 50.0, 40.0, 1 / 12) ≈ 50.0 - 40.0 / 12
        @test AEMSim._max_active_power(10.0, 50.0, 40.0, 1 / 12) == 50.0 - 40.0 * (1 / 12)
    end
    @testset "_max_active_power uses the initial_mw it is given" begin
        low = AEMSim._max_active_power(0.0, 10.0, 60.0, 1 / 12)
        high = AEMSim._max_active_power(0.0, 100.0, 60.0, 1 / 12)
        @test low == 5.0
        @test high == 95.0
    end
    @testset "_agc_ramp_rate takes the larger of the ramp and availability per hour" begin
        @test AEMSim._agc_ramp_rate(5.0, 1.0, 1 / 12) == 12.0
        @test AEMSim._agc_ramp_rate(5.0, NaN, 1 / 12) == 5.0
        @test AEMSim._agc_ramp_rate(5.0, 0.0, 1 / 12) == 5.0
        @test isnan(AEMSim._agc_ramp_rate(NaN, 1.0, 1 / 12))
    end
end


@testset "Dispatch limits derived from unit conditions" begin
    AEMSim = AustralianElectricityMarketsSimulations
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    sys_base, _ = nem_network(db)
    resolution = Minute(5)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:resolution:(start_date + Hour(2))
    base_power = get_base_power(sys_base)
    truth = read_unit_conditions(db, date_range)

    @testset "a one-interval range is refused, as a single-value series is at HEAD" begin
        one = start_date:resolution:(start_date + resolution)
        @test_throws ArgumentError set_unit_conditions!(deepcopy(sys_base), db, one)
    end

    @testset "a non-scheduled load keeps its metered ramp for AGC and zeros its ramp limit" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_unit_conditions!(sys, db, date_range)
        set_effective_offers!(sys)
        asload = get_component(NEMLoad, sys, "ASLOAD1")
        @test all(==(0.0), get_time_series_values(SingleTimeSeries, asload, "ramp_up_rate"; ignore_scaling_factors = true))
        rows = sort(subset(truth, :DUID => ByRow(==("ASLOAD1"))), :SETTLEMENTDATE)
        got = get_time_series_values(SingleTimeSeries, asload, fcas_series_name("fcas_agc_ramp_rate", BidType.RAISEREG))
        # A ControllableLoad raises regulation from its ramp-up rate and its lower availability, per hour.
        raise(ramp, avail) = isnan(avail) ? ramp : max(ramp, avail * 12)
        expected = [raise(r / base_power, a / base_power) for (r, a) in zip(rows.RAMPUPRATE, rows.LOWERREGAVAILABILITY)]
        @test isapprox(got, expected; nans = true)
    end

    @testset "the ramp-down floor above AVAILABILITY raises max_active_power to the floor" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_unit_conditions!(sys, db, date_range)
        device = get_component(NEMThermalGen, sys, "ER01")
        full_grid = collect(date_range)[1:(end - 1)]
        n = length(full_grid)
        replace_single_series!(sys, device, single_series(NEM_SERIES.availability, full_grid, zeros(n)))
        replace_single_series!(sys, device, single_series(NEM_SERIES.initial_mw, full_grid, fill(100.0 / base_power, n)))
        replace_single_series!(sys, device, single_series(NEM_SERIES.dispatch_ramp_down_rate, full_grid, fill(60.0 / 60 / base_power, n)))
        AEMSim._set_dispatch_limits!(sys)
        # 100 MW less 60 MW/h over one 5-minute interval is the 95 MW floor, above the zero availability.
        static = with_units_base(() -> get_max_active_power(device), sys, "NATURAL_UNITS")
        got = get_time_series_values(SingleTimeSeries, device, "max_active_power"; ignore_scaling_factors = true)
        @test isapprox(got, fill(95.0 / static, n); atol = 1.0e-12)
    end

    @testset "a device without unit conditions gets no limit series" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_unit_conditions!(sys, db, date_range)
        device = get_component(NEMThermalGen, sys, "ER01")
        remove_single_series!(sys, device, NEM_SERIES.dispatch_ramp_up_rate)
        AEMSim._set_dispatch_limits!(sys)
        @test !has_time_series(device, SingleTimeSeries, NEM_SERIES.ramp_up_rate)
        @test !has_time_series(device, SingleTimeSeries, NEM_SERIES.max_active_power)
    end
end
