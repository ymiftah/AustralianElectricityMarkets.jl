# Effective FCAS offers and tie-break scales, derived by `set_effective_offers!` (run by `prepare_replay!`),
# and the accessors that read the derived inputs.

# A unit first registered at `stamp`: its summary and loss-factor rows start there, and its bids and
# dispatch rows before it are removed, as NEMWEB has them. Returns the hive location.
function registered_from(source, duid, stamp)
    t = "TIMESTAMP '$stamp'"
    steps = [
        (:DUDETAILSUMMARY, "UPDATE input SET START_DATE = $t WHERE DUID = '$duid'"),
        (:DUDETAIL, "UPDATE input SET EFFECTIVEDATE = $t WHERE DUID = '$duid'"),
        (:BIDPEROFFER_D, "DELETE FROM input WHERE DUID = '$duid' AND INTERVAL_DATETIME <= $t"),
        # Keeps the row at the registration stamp: it is the previous row of the first registered interval.
        (:DISPATCHLOAD, "DELETE FROM input WHERE DUID = '$duid' AND SETTLEMENTDATE < $t"),
    ]
    for (table, query) in steps
        source = damaged_cache(source, table, query).config.hive_location
    end
    return source
end

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
        er01 = get_component(ThermalStandard, sys, "ER01")
        bw01 = get_component(EnergyReservoirStorage, sys, "BW01")
        asload1 = get_component(InterruptiblePowerLoad, sys, "ASLOAD1")
        prices_ascending = [51.0, 52.0, 53.0, 54.0, 55.0, 56.0, 57.0, 58.0, 59.0, 60.0]
        prices_descending = reverse(prices_ascending)
        bands = [0.0, 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0]

        @test PowerSystems.get_x_coords(first(values_of(er01, "energy_offer"))) == bands
        @test PowerSystems.get_y_coords(first(values_of(er01, "energy_offer"))) == prices_ascending
        @test first(values_of(er01, "energy_availability")) ≈ 1.01
        @test PowerSystems.get_y_coords(first(values_of(bw01, "energy_offer_decremental"))) == prices_descending
        @test first(values_of(bw01, "energy_availability_decremental")) ≈ 1.01
        @test PowerSystems.get_y_coords(first(values_of(bw01, AustralianElectricityMarkets._fcas_offer_series_name(bw01, BidType.RAISEREG, false)))) == prices_ascending
        @test isequal(
            collect(
                Tuple(
                    first(
                        AustralianElectricityMarketsSimulations._fcas_trapezium_window(
                            bw01, AustralianElectricityMarketsSimulations._fcas_bid_inputs(bw01, BidType.RAISEREG, OfferSide.GEN), start_date + Minute(5), 1,
                        )
                    )
                )
            ),
            [0.2, 0.3, 0.9, 1.0, 0.21, NaN, NaN],
        )
        @test PowerSystems.get_y_coords(first(values_of(asload1, AustralianElectricityMarkets._fcas_offer_series_name(asload1, BidType.RAISE6SEC, true)))) == prices_descending
    end

    @testset "get_fcas_offer reads the scaled trapezium and the offer curve" begin
        sys = first(nem_network(db))
        set_market_bids!(sys, db, date_range)
        set_unit_conditions!(sys, db, date_range)
        set_effective_offers!(sys)
        horizon = length(date_range) - 1
        # ASLOAD1 is a zero-cost non-scheduled load, so its decremental offer is read from its own series.
        asload1 = get_component(InterruptiblePowerLoad, sys, "ASLOAD1")
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
            gen = ThermalStandard(;
                name = name, available = true, status = true, bus = bus,
                active_power = 0.0, reactive_power = 0.0, rating = 1.0,
                active_power_limits = (min = 0.0, max = 1.0), reactive_power_limits = nothing,
                ramp_limits = nothing,
                operation_cost = ThermalGenerationCost(nothing),
                base_power = 100.0, time_limits = nothing, must_run = false,
                prime_mover_type = PrimeMovers.ST, fuel = ThermalFuels.COAL,
            )
            add_component!(sys, gen)
            AustralianElectricityMarkets.attach_nem_unit_data!(sys, gen)
            # A static observed state keeps the build's first-solve seed out of these offer fixtures.
            AustralianElectricityMarkets.set_observed_state!(
                gen, AustralianElectricityMarkets.NEMObservedState(; initial_mw = 0.0, dispatch_mode = 0),
            )
            _toy_energy_bid!(sys, gen, AustralianElectricityMarkets.BidDirection.GEN, [start, start + Minute(5)], fill(curve, 2), fill(PSY.get_base_power(sys), 2))
        end

        set_effective_offers!(sys)
        g1, g2 = get_component(ThermalStandard, sys, "G1"), get_component(ThermalStandard, sys, "G2")
        @test get_time_series_values(SingleTimeSeries, g1, "tie_break_scale_1") ≈ [1.0, 1.0]
        @test get_time_series_values(SingleTimeSeries, g2, "tie_break_scale_1") ≈ [0.4, 0.4]
        @test get_time_series_values(SingleTimeSeries, g1, "tie_break_scale_2") ≈ [10.0 / 13.0, 10.0 / 13.0]
        @test get_time_series_values(SingleTimeSeries, g2, "tie_break_scale_2") ≈ [1.0, 1.0]

        json_path = joinpath(mktempdir(), "sys.json")
        to_json(sys, json_path)
        sys2 = System(json_path)

        service = get_component(EnergyTieBreak, sys2, "energy_tie_break")
        @test sort!(get_name.(get_contributing_devices(sys2, service))) == ["G1", "G2"]
        @test get_time_series_values(SingleTimeSeries, get_component(ThermalStandard, sys2, "G2"), "tie_break_scale_1") ≈ [0.4, 0.4]
        @test get_time_series_values(SingleTimeSeries, get_component(ThermalStandard, sys2, "G1"), "tie_break_scale_2") ≈ [10.0 / 13.0, 10.0 / 13.0]
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
                gen = ThermalStandard(;
                    name = name, available = true, status = true, bus = bus,
                    active_power = 0.0, reactive_power = 0.0, rating = 1.0,
                    active_power_limits = (min = 0.0, max = 1.0), reactive_power_limits = nothing,
                    ramp_limits = nothing, operation_cost = ThermalGenerationCost(nothing), base_power = 100.0, time_limits = nothing,
                    must_run = false, prime_mover_type = PrimeMovers.ST, fuel = ThermalFuels.COAL,
                )
                add_component!(sys, gen)
                AustralianElectricityMarkets.attach_nem_unit_data!(sys, gen)
                AustralianElectricityMarkets.set_observed_state!(
                    gen, AustralianElectricityMarkets.NEMObservedState(; initial_mw = 0.0, dispatch_mode = 0),
                )
            end
            pump = InterruptiblePowerLoad(;
                name = "PUMP2", available = true, bus = bus, active_power = 0.0, reactive_power = 0.0,
                max_active_power = 1.0, max_reactive_power = 0.0, base_power = 100.0,
                operation_cost = LoadCost(; variable = CostCurve(LinearCurve(0.0)), fixed = 0.0),
            )
            add_component!(sys, pump)
            AustralianElectricityMarkets.attach_nem_unit_data!(sys, pump)
            AustralianElectricityMarkets.set_observed_state!(
                get_component(InterruptiblePowerLoad, sys, "PUMP2"),
                AustralianElectricityMarkets.NEMObservedState(; initial_mw = 0.0, dispatch_mode = 0),
            )
            return sys
        end

        @testset "GEN and LOAD prices use their own loss factor" begin
            sys = unit_system()
            gen = get_component(ThermalStandard, sys, "GEN1")
            load = get_component(InterruptiblePowerLoad, sys, "PUMP2")
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
            gen = get_component(ThermalStandard, sys, "GEN1")
            AustralianElectricityMarkets._nem_unit_data(gen).offer = NEMOfferCost(;
                energy = [
                    NEMEnergyBid(;
                        direction = AustralianElectricityMarkets.BidDirection.GEN,
                        offer_curves = PiecewiseStepData([0.0, 10.0], [5.0]), max_avail = 10.0, roc_up = 0.0, roc_down = 0.0,
                    ),
                ],
            )
            @test_throws ArgumentError set_effective_offers!(sys)
        end

        @testset "two FCAS bids of one service on one side are rejected" begin
            sys = unit_system()
            gen = get_component(ThermalStandard, sys, "GEN2")
            for direction in (AustralianElectricityMarkets.BidDirection.GEN, AustralianElectricityMarkets.BidDirection.BIDIRECTIONAL)
                name(f) = bid_series_name(BidType.RAISE6SEC, f, direction)
                replace_single_series_with!(sys, gen, name(:offer_curves), fill(PiecewiseStepData([0.0, 10.0], [5.0]), 2), stamps)
                replace_single_series_with!(sys, gen, name(:max_avail), fill(10.0, 2), stamps)
                replace_single_series_with!(sys, gen, name(:trapezium), fill((0.0, 10.0, 90.0, 100.0), 2), stamps)
                AustralianElectricityMarkets._set_fcas_bid!(
                    AustralianElectricityMarkets._nem_offer_cost(gen),
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

    @testset "a device with no dispatch rows before its registration does not abort the replay" begin
        # BW02 registers after 00:10, so both steps of this replay precede its registration. The
        # first solve reads the build's seeds; the per-step update must resolve the same stamps to the
        # same seed state (zero output, dispatch mode 0, no fixed loading) instead of throwing on the
        # absent dispatch mode.
        steps = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 10)
        late_hive = registered_from(AEM_TEST_REPLAY_HIVE_DIR, "BW02", "2025-01-01 00:10:00")
        late = nem_system(
            aem_connect(HiveConfiguration(hive_location = late_hive, filesystem = "file")), NEMDEConfiguration();
            date_range = first(steps):Minute(5):(last(steps) + 2Minute(5)),
        )
        out = run_replay(late, steps)
        @test length(PSI.read_optimizer_stats(out.results).objective_value) == length(steps)

        # The decision problem's final solve is step 2, at 00:10, which is still before the registration.
        container = PSI.get_optimization_container(out.model)
        initial = PSI.get_parameter(container, PSI.ParameterKey(AEMS.InitialPowerTimeSeriesParameter, HydroDispatch))
        target = PSI.get_parameter(container, PSI.ParameterKey(AEMS.FixedLoadTimeSeriesParameter, HydroDispatch))
        invoked = PSI.get_parameter(container, PSI.ParameterKey(AEMS.FixedLoadInvokedTimeSeriesParameter, HydroDispatch))
        @test only(PSI.get_parameter_column_values(initial, "BW02")) === 0.0
        @test only(PSI.get_parameter_column_values(target, "BW02")) === 0.0
        @test only(PSI.get_parameter_column_values(invoked, "BW02")) === 0.0
        # The build's seeds agree with those values at both stamps, and the state the update reads there is
        # the zero state the seed came from.
        bw02 = get_component(HydroDispatch, PSI.get_system(out.model), "BW02")
        @test get_time_series_values(SingleTimeSeries, bw02, "initial_mw_seed"; ignore_scaling_factors = true)[1:2] == [0.0, 0.0]
        @test AEMS.unit_state(AEMS.ObservedState(), bw02, last(steps)) == AEMS.NEMUnitState(0.0, 0)
    end

    @testset "the first-solve seed needs the output, not the dispatch mode" begin
        # The unit is registered at both stamps, and its dispatch mode is NaN at the second: `unit_state`
        # throws there, but the seed reads only the output.
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0;
            mutate! = function (sys, stamps)
                cheap = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
                set_toy_unit_field!(sys, cheap, stamps, :dispatch_mode, [0.0, NaN])
                return
            end,
        )
        cheap = get_component(ThermalStandard, sys, TOY_CHEAP)
        stamps = [TOY_START, TOY_START + TOY_RESOLUTION]
        @test_throws ArgumentError AEMS.unit_state(AEMS.ObservedState(), cheap, last(stamps))
        # The seed series cannot be rewritten on a transformed toy, so the seed function is read directly.
        @test [AEMS._state_initial_mw(AEMS.ObservedState(), cheap, t) for t in stamps] == [50.0, 50.0]
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
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_available!(get_component(ThermalStandard, sys, "ER02"), false)
        load = get_component(InterruptiblePowerLoad, sys, "PUMP1")
        horizon = length(date_range) - 1
        trap = (0.0, 10.0, 90.0, 100.0, 20.0)
        for service in (BidType.RAISEREG, BidType.LOWERREG)
            add_toy_fcas_offer!(
                sys, load, [start_date + (i - 1) * resolution for i in 1:horizon], service,
                fill(trap, horizon), fill([(20.0, 10.0)], horizon); decremental = true,
            )
        end
        set_unit_conditions!(sys, rates_db, date_range)
        set_effective_offers!(sys)
        with_units_base(sys, "NATURAL_UNITS") do
            raise = get_scaled_fcas_trapezium(load, BidType.RAISEREG, start_date, horizon; decremental = true)
            lower = get_scaled_fcas_trapezium(load, BidType.LOWERREG, start_date, horizon; decremental = true)
            @test get_max_avail.(raise) ≈ fill(5.0, horizon)
            @test get_max_avail.(lower) ≈ fill(10.0, horizon)
            raw = AustralianElectricityMarketsSimulations._get_fcas_trapezium(load, BidType.RAISEREG, start_date, horizon; decremental = true)
            @test get_max_avail.(raw) == fill(20.0, horizon)
        end
    end

    @testset "load regulation availability pairs with its own service" begin
        rates_db = damaged_cache(
            hive_dir, :DISPATCHLOAD,
            "UPDATE input SET RAMPUPRATE = 180, RAMPDOWNRATE = 720, RAISEREGAVAILABILITY = 0, LOWERREGAVAILABILITY = 60, RAISEREGENABLEMENTMIN = 0, RAISEREGENABLEMENTMAX = 0, LOWERREGENABLEMENTMIN = 0, LOWERREGENABLEMENTMAX = 0 WHERE DUID = 'PUMP1'",
        )
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_available!(get_component(ThermalStandard, sys, "ER02"), false)
        load = get_component(InterruptiblePowerLoad, sys, "PUMP1")
        horizon = length(date_range) - 1
        trap = (0.0, 10.0, 90.0, 100.0, 100.0)
        for service in (BidType.RAISEREG, BidType.LOWERREG)
            add_toy_fcas_offer!(
                sys, load, [start_date + (i - 1) * resolution for i in 1:horizon], service,
                fill(trap, horizon), fill([(20.0, 10.0)], horizon); decremental = true,
            )
        end
        set_unit_conditions!(sys, rates_db, date_range)
        set_effective_offers!(sys)
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

        device = get_component(ThermalStandard, sys, "ER01")
        full_grid = collect(date_range)[1:(end - 1)]
        horizon = length(full_grid)
        # 60 MW/h is a 5 MW AGC ramping capability over 5 minutes.
        ramp = [t == first(full_grid) ? NaN : 60.0 for t in full_grid]
        replace_single_series!(sys, device, single_series(AustralianElectricityMarkets.NEM_TELEMETRY_SERIES.ramp_up_limit, full_grid, ramp))
        AustralianElectricityMarketsSimulations._set_dispatch_limits!(sys)

        raw, scaled = with_units_base(sys, "NATURAL_UNITS") do
            (
                AustralianElectricityMarketsSimulations._get_fcas_trapezium(device, BidType.RAISEREG, start_date, horizon),
                get_scaled_fcas_trapezium(device, BidType.RAISEREG, start_date, horizon),
            )
        end
        @test get_max_avail(raw[1]) > 5.0
        # Without a ramp rate at an interval, the ramp limit there is zero, as HEAD.
        @test get_time_series_values(SingleTimeSeries, device, "ramp_up_rate")[1] == 0.0
        @test isequal(get_max_avail(scaled[1]), get_max_avail(raw[1]))
        @test all(i -> isapprox(get_max_avail(scaled[i]), min(get_max_avail(raw[i]), 5.0)), 2:horizon)
    end

    @testset "FCAS trapeziums are read from the bid series" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_unit_conditions!(sys, db, date_range)
        set_effective_offers!(sys)
        device = get_component(ThermalStandard, sys, "ER01")
        horizon = length(date_range) - 1
        inputs = AustralianElectricityMarketsSimulations._fcas_bid_inputs(device, BidType.RAISEREG, OfferSide.GEN)
        window = AustralianElectricityMarketsSimulations._fcas_trapezium_window(device, inputs, start_date, horizon)
        bid(field) = AustralianElectricityMarkets.bid_series_name(BidType.RAISEREG, field, AustralianElectricityMarkets.BidDirection.GEN)
        points = get_time_series_values(SingleTimeSeries, device, bid(:trapezium))
        max_avail = get_time_series_values(SingleTimeSeries, device, bid(:max_avail))
        base = get_base_power(sys)
        @test length(window) == horizon
        @test all(i -> isequal(Tuple(window[i]), fcas_trapezium_values(points[i], max_avail[i], base)), eachindex(window))
        @test !any(startswith("fcas_trapezium"), [get_name(k) for k in get_time_series_keys(device)])
    end

    @testset "get_scaled_fcas_trapezium narrows the trapezium wherever the AGC input is more restrictive" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_unit_conditions!(sys, db, date_range)
        set_effective_offers!(sys)
        AustralianElectricityMarketsSimulations._set_dispatch_limits!(sys)

        device = get_component(ThermalStandard, sys, "ER01")
        initial_time = start_date
        horizon = length(date_range) - 1

        raw = AustralianElectricityMarketsSimulations._get_fcas_trapezium(device, BidType.RAISEREG, initial_time, horizon)
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
            raw_mw = with_units_base(() -> get_max_avail.(AustralianElectricityMarketsSimulations._get_fcas_trapezium(device, BidType.RAISEREG, initial_time, horizon)), sys, "NATURAL_UNITS")
            @test isapprox(
                get_max_avail.(scaled_i),
                min.(raw_mw, max.(rows.RAMPUPRATE, rows.RAISEREGAVAILABILITY .* 12) .* hours); atol = 1.0e-6,
            )
        end

        # A contingency market carries no AGC scaling input series at all: unscaled.
        raw_contingency = AustralianElectricityMarketsSimulations._get_fcas_trapezium(device, BidType.RAISE6SEC, initial_time, horizon)
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
        set_unit_conditions!(sys, db, date_range)
        set_effective_offers!(sys)
        for bat in get_components(EnergyReservoirStorage, sys)
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
        @test isnothing(get_storage_energy_max_avail(first(get_components(ThermalStandard, sys)), start_date, 1))
        @test isnothing(get_energy_offer(first(get_components(PowerLoad, sys)), OfferSide.GEN))
    end

    @testset "a device without NEM unit data has no offer view" begin
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
        set_unit_conditions!(sys, db, date_range)
        set_effective_offers!(sys)
        gen = first(get_components(ThermalStandard, sys))
        storage = first(get_components(EnergyReservoirStorage, sys))
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
        set_unit_conditions!(sys, db, date_range)
        set_effective_offers!(sys)
        set_market_bids!(sys, db, second_range)
        set_effective_offers!(sys)
        for device in vcat(collect(get_components(ThermalStandard, sys)), collect(get_components(EnergyReservoirStorage, sys)))
            get_available(device) || continue
            for side in [AustralianElectricityMarkets._energy_offer_side(b.direction) for b in AustralianElectricityMarkets.get_energy_bids(AustralianElectricityMarkets._nem_offer_cost(device))]
                @test get_energy_offer(device, side).timestamps[1] == second_range[1]
            end
        end
    end

    @testset "initial_mw reads back as DISPATCHLOAD, and availability is the bid MAXAVAIL" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range)
        attach_dispatch_limits!(sys, db, date_range)
        set_available!(get_component(ThermalStandard, sys, "ER02"), false)
        set_effective_offers!(sys)
        renewable = get_component(RenewableDispatch, sys, "BW03")
        battery = get_component(EnergyReservoirStorage, sys, "BW01")
        with_units_base(sys, "NATURAL_UNITS") do
            for (device, duid) in ((renewable, "BW03"), (battery, "BW01"))
                rows = sort(subset(truth, :DUID => ByRow(==(duid))), :SETTLEMENTDATE)
                @test isapprox(get_initial_mw(device, start_date, horizon), rows.INITIALMW; atol = 1.0e-8)
            end
            rows = sort(subset(truth, :DUID => ByRow(==("BW03"))), :SETTLEMENTDATE)
            # The mock's AVAILABILITY is synthetic; the real-data gate checks the derivation against it.
            max_avail = get_time_series_values(SingleTimeSeries, renewable, energy_availability_series_name(renewable, OfferSide.GEN); start_time = start_date, len = horizon)
            uigf = get_time_series_values(SingleTimeSeries, renewable, get_name(get_telemetry(renewable).uigf); start_time = start_date, len = horizon)
            @test isapprox(get_energy_availability(renewable, start_date, horizon), min.(max_avail .* get_base_power(sys), uigf); atol = 1.0e-8)
        end
        # A battery's availability comes from its energy bid, not AVAILABILITY.
        @test isnothing(get_energy_availability(battery, start_date, horizon))
    end

    @testset "get_initial_mw throws, naming the unit, when it has no observed state" begin
        sys = deepcopy(sys_base)
        bat = get_component(EnergyReservoirStorage, sys, "BW01")
        err = try
            get_initial_mw(bat, start_date, horizon)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("BW01", sprint(showerror, err))
    end

    @testset "get_fcas_agc_status reads back AGCSTATUS and throws for a unit with no telemetry" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range)
        set_available!(get_component(ThermalStandard, sys, "ER02"), false)
        set_unit_conditions!(sys, db, date_range)
        set_effective_offers!(sys)
        device = get_component(ThermalStandard, sys, "ER01")
        rows = sort(subset(scaling_truth, :DUID => ByRow(==("ER01"))), :SETTLEMENTDATE)
        @test get_fcas_agc_status(device, start_date, horizon) == round.(Int, rows.AGCSTATUS)
        load = get_component(InterruptiblePowerLoad, sys, "PUMP1")
        @test get_fcas_agc_status(load, start_date, horizon) == ones(Int, horizon)

        bare = deepcopy(sys_base)
        @test_throws ArgumentError get_fcas_agc_status(get_component(ThermalStandard, bare, "ER01"), start_date, horizon)
    end

    @testset "get_fcas_agc_status is nothing at an interval with no AGCSTATUS" begin
        sys = deepcopy(sys_base)
        set_unit_conditions!(sys, db, date_range)
        device = get_component(ThermalStandard, sys, "ER01")
        full_grid = collect(date_range)[1:(end - 1)]
        status = [t == first(full_grid) ? NaN : 1.0 for t in full_grid]
        replace_single_series!(sys, device, single_series(AustralianElectricityMarkets.NEM_TELEMETRY_SERIES.agc_status, full_grid, status))
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
        asload = get_component(InterruptiblePowerLoad, sys, "ASLOAD1")
        @test all(==(0.0), get_time_series_values(SingleTimeSeries, asload, "ramp_up_rate"; ignore_scaling_factors = true))
        rows = sort(subset(truth, :DUID => ByRow(==("ASLOAD1"))), :SETTLEMENTDATE)
        got = get_time_series_values(SingleTimeSeries, asload, fcas_series_name("fcas_agc_ramp_rate", BidType.RAISEREG))
        # A ControllableLoad raises regulation from its ramp-up rate and its lower availability, per hour.
        raise(ramp, avail) = isnan(avail) ? ramp : max(ramp, avail * 12)
        expected = [raise(r / base_power, a / base_power) for (r, a) in zip(rows.RAMPUPRATE, rows.LOWERREGAVAILABILITY)]
        @test isapprox(got, expected; nans = true)
    end

    @testset "a device bidding regulation on both sides has the summed bid max availability" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_unit_conditions!(sys, db, date_range)
        set_effective_offers!(sys)
        battery = get_component(EnergyReservoirStorage, sys, "BW01")
        telemetry = get_telemetry(battery)
        up = AEMSim._bid_series(battery, telemetry.ramp_up_limit, :ramp_up_limit)
        n = length(up.values)
        # A telemetered availability above the combined bid leaves the bid sum binding.
        replace_single_series!(
            sys, battery,
            single_series(NEM_TELEMETRY_SERIES.raise_reg_max_avail, first(up.timestamps), fill(1.0e6, n), up.resolution),
        )
        both = AEMSim._regulation_availability(battery, BidType.RAISEREG, telemetry.raise_reg_max_avail, up, base_power)
        cost = AustralianElectricityMarkets._nem_offer_cost(battery)
        @test count(b -> b.service == BidType.RAISEREG, get_fcas_bids(cost)) == 2
        filter!(b -> !(b.service == BidType.RAISEREG && get_direction(b) == BidDirection.LOAD), get_fcas_bids(cost))
        one = AEMSim._regulation_availability(battery, BidType.RAISEREG, telemetry.raise_reg_max_avail, up, base_power)
        # Both sides bid the same MAXAVAIL in the fixture, so the combined availability is twice one side's.
        @test all(both .> 0)
        @test both ≈ 2 .* one
    end

    @testset "the dispatch-limit writer leaves the upper limit to the formulation" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_unit_conditions!(sys, db, date_range)
        set_available!(get_component(ThermalStandard, sys, "ER02"), false)
        set_available!(get_component(HydroDispatch, sys, "BW02"), false)
        set_effective_offers!(sys)
        device = get_component(ThermalStandard, sys, "ER01")
        full_grid = collect(date_range)[1:(end - 1)]
        n = length(full_grid)
        replace_single_series!(sys, device, single_series(energy_availability_series_name(device, OfferSide.GEN), full_grid, zeros(n)))
        replace_single_series!(sys, device, single_series(NEM_OBSERVED_SERIES.initial_mw, full_grid, fill(100.0, n)))
        replace_single_series!(sys, device, single_series(NEM_TELEMETRY_SERIES.ramp_down_limit, full_grid, fill(60.0, n)))
        AEMSim._set_dispatch_limits!(sys)
        # The ramp floor above the availability is a formulation row and its slack, not a written series.
        @test has_time_series(device, SingleTimeSeries, NEM_SERIES.ramp_down_rate)
        @test !has_time_series(device, SingleTimeSeries, NEM_SERIES.max_active_power)
    end

    @testset "a device without telemetry gets no ramp series, and its telemetry accessor throws" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_unit_conditions!(sys, db, date_range)
        set_available!(get_component(ThermalStandard, sys, "ER02"), false)
        set_available!(get_component(HydroDispatch, sys, "BW02"), false)
        set_effective_offers!(sys)
        device = get_component(ThermalStandard, sys, "ER01")
        remove_single_series!(sys, device, NEM_SERIES.ramp_up_rate)
        AustralianElectricityMarkets.set_telemetry!(device, nothing)
        AEMSim._set_dispatch_limits!(sys)
        @test !has_time_series(device, SingleTimeSeries, NEM_SERIES.ramp_up_rate)
        @test !has_time_series(device, SingleTimeSeries, NEM_SERIES.max_active_power)
        err = try
            AustralianElectricityMarkets.get_telemetry(device)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("ER01 has no telemetry", sprint(showerror, err))
    end

    @testset "dispatch ramps are the lesser of the bid and telemetry, read on the side the device bids" begin
        # A generator bids ROCUP 2 MW/min (120 MW/h) against a 100 MW/min telemetry (6000 MW/h), so the
        # bid binds, while its ROCDOWN 100 MW/min loses to the 50 MW/min telemetry. A scheduled load's
        # energy bid is on its LOAD side only, and its ROCUP 4 MW/min binds the same way.
        units = [
            TOY_CHEAP => toy_unit(
                100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0, ramp_down = 50.0,
                roc_up = 2.0, roc_down = 100.0,
            ),
        ]
        loads = [
            "pump" => toy_load(
                40.0, 300.0; initial = 20.0, ramp_up = 100.0, ramp_down = 50.0,
                roc_up = 4.0, roc_down = 100.0,
            ),
        ]
        sys = nem_toy_system(units, [60.0, 80.0]; loads)
        base = get_base_power(sys)
        derived(device, name) = get_time_series_values(SingleTimeSeries, device, name; ignore_scaling_factors = true)
        cheap = get_component(ThermalStandard, sys, TOY_CHEAP)
        pump = get_component(InterruptiblePowerLoad, sys, "pump")
        @test all(isapprox.(derived(cheap, NEM_SERIES.ramp_up_rate), 2.0 / base; atol = 1.0e-12))
        @test all(isapprox.(derived(cheap, NEM_SERIES.ramp_down_rate), 50.0 / base; atol = 1.0e-12))
        @test all(isapprox.(derived(pump, NEM_SERIES.ramp_up_rate), 4.0 / base; atol = 1.0e-12))
        @test all(isapprox.(derived(pump, NEM_SERIES.ramp_down_rate), 50.0 / base; atol = 1.0e-12))
    end
end


@testset "Derived availability: zero branches, the MAXAVAIL branch, and the struct-key check" begin
    AEMSim = AustralianElectricityMarketsSimulations
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    sys_base, _ = nem_network(db)
    resolution = Minute(5)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:resolution:(start_date + Hour(2))
    horizon = length(date_range) - 1
    full_grid = collect(date_range)[1:(end - 1)]

    function built()
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_available!(get_component(ThermalStandard, sys, "ER02"), false)
        set_available!(get_component(HydroDispatch, sys, "BW02"), false)
        set_unit_conditions!(sys, db, date_range)
        set_effective_offers!(sys)
        return sys
    end

    @testset "a non-scheduled load has zero availability and no dispatch-limit series" begin
        sys = built()
        asload = get_component(InterruptiblePowerLoad, sys, "ASLOAD1")
        @test AustralianElectricityMarkets.is_non_scheduled_load(asload)
        @test all(==(0.0), get_energy_availability(asload, start_date, horizon))
        # The upper limit is the formulation's row, so the build writes no max_active_power series.
        @test !has_time_series(asload, SingleTimeSeries, NEM_SERIES.max_active_power)
    end

    @testset "an interval with no DISPATCHLOAD row (NaN ramp) has zero availability" begin
        sys = built()
        device = get_component(ThermalStandard, sys, "ER01")
        ramps = fill(60.0, length(full_grid))
        ramps[2] = NaN
        replace_single_series!(sys, device, single_series(NEM_TELEMETRY_SERIES.ramp_up_limit, full_grid, ramps))
        avail = get_energy_availability(device, start_date, horizon)
        @test avail[2] == 0.0
        @test avail[1] > 0.0
    end

    @testset "a scheduled unit's availability is exactly its energy MAXAVAIL" begin
        sys = built()
        device = get_component(ThermalStandard, sys, "ER01")
        with_units_base(sys, "NATURAL_UNITS") do
            max_avail = get_time_series_values(SingleTimeSeries, device, energy_availability_series_name(device, OfferSide.GEN); start_time = start_date, len = horizon)
            @test get_energy_availability(device, start_date, horizon) ≈ max_avail .* get_base_power(sys) atol = 1.0e-9
        end
    end

    @testset "a device's observed initial MW may key any series" begin
        sys = built()
        device = get_component(ThermalStandard, sys, "ER01")
        @test AEMSim._has_nem_dispatch_limits(device)
        key = AustralianElectricityMarkets.get_observed_state(device).initial_mw
        values = get_time_series_values(SingleTimeSeries, device, get_name(key); ignore_scaling_factors = true)
        add_time_series!(sys, device, single_series("other_initial", start_date, values, resolution))
        AustralianElectricityMarkets.set_observed_state!(
            device,
            AustralianElectricityMarkets.NEMObservedState(;
                initial_mw = AustralianElectricityMarkets._series_key(device, "other_initial"),
                dispatch_mode = AustralianElectricityMarkets.get_observed_state(device).dispatch_mode,
            ),
        )
        @test AEMSim._has_nem_dispatch_limits(device)
    end

    @testset "a state key whose series is absent fails the pre-flight" begin
        sys = built()
        device = get_component(ThermalStandard, sys, "ER01")
        @test AEMSim._has_nem_dispatch_limits(device)
        key = AustralianElectricityMarkets.get_observed_state(device).initial_mw
        values = get_time_series_values(SingleTimeSeries, device, get_name(key); ignore_scaling_factors = true)
        add_time_series!(sys, device, single_series("other_initial", start_date, values, resolution))
        AustralianElectricityMarkets.set_observed_state!(
            device,
            AustralianElectricityMarkets.NEMObservedState(;
                initial_mw = AustralianElectricityMarkets._series_key(device, "other_initial"),
                dispatch_mode = AustralianElectricityMarkets.get_observed_state(device).dispatch_mode,
            ),
        )
        @test AEMSim._has_nem_dispatch_limits(device)
        PSY.remove_time_series!(sys, SingleTimeSeries, device, "other_initial")
        @test !AEMSim._has_nem_dispatch_limits(device)
    end

    @testset "a re-keyed initial MW leaves the default name unused" begin
        sys = built()
        device = get_component(ThermalStandard, sys, "ER01")
        @test AEMSim._has_nem_dispatch_limits(device)
        key = AustralianElectricityMarkets.get_observed_state(device).initial_mw
        values = get_time_series_values(SingleTimeSeries, device, get_name(key); ignore_scaling_factors = true)
        add_time_series!(sys, device, single_series("other_initial", start_date, values, resolution))
        AustralianElectricityMarkets.set_observed_state!(
            device,
            AustralianElectricityMarkets.NEMObservedState(;
                initial_mw = AustralianElectricityMarkets._series_key(device, "other_initial"),
                dispatch_mode = AustralianElectricityMarkets.get_observed_state(device).dispatch_mode,
            ),
        )
        @test AEMSim._has_nem_dispatch_limits(device)
        # The state's key names the series it reads; the default name is only a convenience.
        PSY.remove_time_series!(sys, SingleTimeSeries, device, "observed_initial_mw")
        @test AEMSim._has_nem_dispatch_limits(device)
        @test isnothing(AEMSim._check_state_series_alignment(device))
    end

    @testset "a derived input key that is not the registered series throws, naming it" begin
        sys = built()
        device = get_component(ThermalStandard, sys, "ER01")
        @test AEMSim._has_nem_dispatch_limits(device)
        old = only(PSY.get_supplemental_attributes(NEMDispatchInputs, device))
        ramps = get_time_series_values(SingleTimeSeries, device, NEM_SERIES.ramp_up_rate; ignore_scaling_factors = true)
        add_time_series!(sys, device, single_series("other_ramp", start_date, ramps, resolution))
        PSY.remove_supplemental_attribute!(sys, device, old)
        PSY.add_supplemental_attribute!(
            sys,
            device,
            NEMDispatchInputs(;
                energy_offer = old.energy_offer,
                energy_offer_decremental = old.energy_offer_decremental,
                energy_availability = old.energy_availability,
                energy_availability_decremental = old.energy_availability_decremental,
                uigf = old.uigf,
                ramp_up = AustralianElectricityMarkets._series_key(device, "other_ramp"),
                ramp_down = old.ramp_down,
                fcas = old.fcas,
            ),
        )
        err = try
            AEMSim._has_nem_dispatch_limits(device)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("ER01", sprint(showerror, err))
        @test occursin("other_ramp", sprint(showerror, err))
    end
end


@testset "State-independent derivation: pure functions and the derived-input keys" begin
    AEMSim = AustralianElectricityMarketsSimulations
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    sys_base, _ = nem_network(db)
    resolution = Minute(5)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:resolution:(start_date + Hour(2))
    base_power = get_base_power(sys_base)

    @testset "referred_offer_curves divides the band prices by the loss factor and rounds to cents" begin
        curve = PiecewiseStepData([0.0, 10.0, 20.0], [10.0, 20.0])
        referred = only(referred_offer_curves([curve], 0.9))
        @test get_x_coords(referred) == [0.0, 10.0, 20.0]
        @test get_y_coords(referred) == [11.11, 22.22]
        @test get_y_coords(only(referred_offer_curves([curve], 1.0))) == [10.0, 20.0]
    end

    @testset "effective_ramp_limit takes the lesser of the bid and telemetered rates" begin
        # ROCUP is MW/min: 3 MW/min is 180 MW/h.
        @test effective_ramp_limit(3.0, 200.0) == 180.0
        @test effective_ramp_limit(3.0, 120.0) == 120.0
        @test effective_ramp_limit(NaN, 120.0) == 120.0
        @test isnan(effective_ramp_limit(3.0, NaN))
        up, down = effective_ramp_limits([3.0, NaN], [1.0, 2.0], [200.0, 120.0], [30.0, NaN])
        @test up == [180.0, 120.0]
        @test down[1] == 30.0
        @test isnan(down[2])
    end

    @testset "effective_energy_availability limits MAXAVAIL by UIGF and zeroes the excluded intervals" begin
        @test effective_energy_availability([10.0, 10.0], [8.0, 12.0], [60.0, 60.0], false) == [8.0, 10.0]
        @test effective_energy_availability([10.0, 10.0], nothing, [60.0, 60.0], false) == [10.0, 10.0]
        @test effective_energy_availability([10.0, 10.0], nothing, [60.0, NaN], false) == [10.0, 0.0]
        @test effective_energy_availability([10.0, 10.0], [8.0, 8.0], [60.0, 60.0], true) == [0.0, 0.0]
    end

    @testset "effective_regulation_enablement takes the more restrictive of bid and AGC limits" begin
        @test effective_regulation_enablement(20.0, 100.0, 30.0, 90.0) == (30.0, 90.0)
        @test effective_regulation_enablement(20.0, 100.0, 10.0, 120.0) == (20.0, 100.0)
        @test effective_regulation_enablement(20.0, 100.0, nothing, nothing) == (20.0, 100.0)
        @test effective_regulation_enablement(20.0, 100.0, nothing, 0.0) == (20.0, 0.0)
    end

    @testset "effective_regulation_max_avail takes the lesser of the bid and telemetered values" begin
        @test effective_regulation_max_avail(50.0, 30.0) == 30.0
        @test effective_regulation_max_avail(20.0, 30.0) == 20.0
        @test effective_regulation_max_avail(nothing, 30.0) == 30.0
        @test isnan(effective_regulation_max_avail(50.0, NaN))
    end

    @testset "fcas_trapezium_values appends MAXAVAIL and the unpublished ramp rates" begin
        @test isequal(
            fcas_trapezium_values((20.0, 30.0, 90.0, 100.0), 50.0, 100.0),
            (0.2, 0.3, 0.9, 1.0, 0.5, NaN, NaN),
        )
    end

    @testset "tie_break_scale is the band width over the widest band of its group" begin
        @test tie_break_scale(10.0, 40.0) == 0.25
        @test tie_break_scale(40.0, 40.0) == 1.0
        @test tie_break_scale(0.0, 0.0) == 0.0
    end

    @testset "loss_demand_coefficient sums the named regions' demand" begin
        model = InterconnectorLossModel(;
            interconnector = "IC1", from_region = "NSW1", to_region = "VIC1", from_region_loss_share = 0.5,
            loss_constant = 0.0, loss_flow_coefficient = 0.0,
            demand_coefficients = Dict("NSW1" => 0.5, "VIC1" => 1.5), breakpoints = [-100.0, 0.0, 100.0],
        )
        @test loss_demand_coefficient(model, Dict("NSW1" => 100.0, "VIC1" => 200.0)) == 350.0
        @test loss_demand_coefficient(model, Dict("NSW1" => 100.0)) == 50.0
    end

    @testset "the derived series and their keys, and no energy_max_avail series" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_unit_conditions!(sys, db, date_range)
        set_effective_offers!(sys)
        names(device) = [get_name(k) for k in get_time_series_keys(device)]
        for device in get_components(StaticInjection, sys)
            @test !any(startswith("energy_max_avail"), names(device))
        end

        device = get_component(ThermalStandard, sys, "ER01")
        inputs = only(PSY.get_supplemental_attributes(NEMDispatchInputs, device))
        @test get_name(inputs.energy_availability) == "energy_availability"
        @test get_name(inputs.energy_offer) == "energy_offer"
        @test get_name(inputs.ramp_up) == NEM_SERIES.ramp_up_rate
        @test get_name(inputs.ramp_down) == NEM_SERIES.ramp_down_rate
        @test isnothing(inputs.energy_availability_decremental)
        raise_reg = only(entry for entry in inputs.fcas if entry.service == BidType.RAISEREG && entry.side == OfferSide.GEN)
        @test get_name(raise_reg.trapezium) == AustralianElectricityMarkets.bid_series_name(BidType.RAISEREG, :trapezium, AustralianElectricityMarkets.BidDirection.GEN)
        @test get_name(raise_reg.max_avail) == AustralianElectricityMarkets.bid_series_name(BidType.RAISEREG, :max_avail, AustralianElectricityMarkets.BidDirection.GEN)
        @test !any(startswith("fcas_trapezium"), [get_name(k) for k in get_time_series_keys(device)])
        @test get_name(raise_reg.agc_ramp) == fcas_series_name("fcas_agc_ramp_rate", BidType.RAISEREG)

        # An entry exists only for a side with an offer, and an offer always writes its trapezium; one
        # entry per (device, service) carries the service's AGC ramp rate, on the side the device bids.
        for d in nem_dispatch_devices(sys)
            entries = only(PSY.get_supplemental_attributes(NEMDispatchInputs, d)).fcas
            @test all(!isnothing(entry.offer) && !isnothing(entry.trapezium) for entry in entries)
            for service in unique(entry.service for entry in entries)
                group = [entry for entry in entries if entry.service == service]
                carried = [entry for entry in group if !isnothing(entry.agc_ramp)]
                @test length(carried) <= 1
                has_ramp = has_time_series(d, SingleTimeSeries, fcas_series_name("fcas_agc_ramp_rate", service))
                @test length(carried) == (has_ramp ? 1 : 0)
                if !isempty(carried) && any(entry.side == OfferSide.GEN for entry in group)
                    @test only(carried).side == OfferSide.GEN
                end
            end
        end

        # The availability the formulation reads is the bid MAXAVAIL per unit of the base.
        bid = only(AustralianElectricityMarkets.get_energy_bids(AustralianElectricityMarkets._nem_offer_cost(device)))
        max_avail = get_time_series_values(SingleTimeSeries, device, get_name(bid.max_avail); ignore_scaling_factors = true)
        @test get_time_series_values(SingleTimeSeries, device, "energy_availability"; ignore_scaling_factors = true) ≈
            max_avail ./ base_power

        battery = get_component(EnergyReservoirStorage, sys, "BW01")
        battery_inputs = only(PSY.get_supplemental_attributes(NEMDispatchInputs, battery))
        @test get_name(battery_inputs.energy_availability_decremental) == "energy_availability_decremental"
        # A battery bids RAISEREG on both sides: the AGC ramp rate rides on the GEN-side entry.
        reg = [entry for entry in battery_inputs.fcas if entry.service == BidType.RAISEREG]
        @test length(reg) == 2
        @test only(entry for entry in reg if !isnothing(entry.agc_ramp)).side == OfferSide.GEN
    end

    @testset "a device with no FCAS bid gets no fcas inputs" begin
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], [60.0, 80.0],
        )
        cheap = get_component(ThermalStandard, sys, TOY_CHEAP)
        @test isempty(get_fcas_bids(AustralianElectricityMarkets._nem_offer_cost(cheap)))
        @test isempty(only(PSY.get_supplemental_attributes(NEMDispatchInputs, cheap)).fcas)
    end

    @testset "the UIGF parameter reads the telemetry UIGF per unit of the base" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_unit_conditions!(sys, db, date_range)
        set_effective_offers!(sys)
        semi = first(d for d in get_components(RenewableDispatch, sys) if is_semi_scheduled(d))
        inputs = only(PSY.get_supplemental_attributes(NEMDispatchInputs, semi))
        @test get_name(inputs.uigf) == NEM_TELEMETRY_SERIES.uigf
        raw = get_time_series_values(SingleTimeSeries, semi, NEM_TELEMETRY_SERIES.uigf; ignore_scaling_factors = true)
        @test PSI.get_multiplier_value(EnergyUIGFTimeSeriesParameter(), semi, NEMReplayDispatch()) ≈ 1 / base_power
        @test PSI.get_multiplier_value(EnergyMaxAvailTimeSeriesParameter(), semi, NEMReplayDispatch()) == 1.0
        @test length(raw) > 0
    end
end


@testset "State-dependent derivation: pure functions of the unit state" begin
    AEMSim = AustralianElectricityMarketsSimulations
    replay_db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    resolution = Minute(5)
    Δ = interval_hours(resolution)

    function replay_system()
        sys = nem_system(replay_db, NEMDEConfiguration(); date_range = interval)
        set_effective_offers!(sys)
        return sys
    end
    values_of(device, name) = get_time_series_values(SingleTimeSeries, device, name; ignore_scaling_factors = true)

    @testset "the max_active_power floor rises with Initial MW" begin
        # 60 MW/h over one 5-minute interval is a 5 MW ramp-down allowance.
        @test max_active_power_floor(100.0, 60.0, Δ, NEMUnitState(50.0, 4)) == 100.0
        @test max_active_power_floor(0.0, 60.0, Δ, NEMUnitState(50.0, 4)) == 45.0
        @test max_active_power_floor(0.0, 60.0, Δ, NEMUnitState(100.0, 4)) == 95.0
        @test max_active_power_floor(0.0, 60.0, Δ, NEMUnitState(100.0, 4)) >
            max_active_power_floor(0.0, 60.0, Δ, NEMUnitState(50.0, 4))
    end

    @testset "fixed loading is invoked outside the fast-start profile" begin
        @test in_fast_start_profile(NEMUnitState(10.0, 1))
        @test in_fast_start_profile(NEMUnitState(10.0, 2))
        @test !in_fast_start_profile(NEMUnitState(10.0, 0))
        @test !in_fast_start_profile(NEMUnitState(10.0, 3))
        @test !in_fast_start_profile(NEMUnitState(10.0, 4))
        @test fixed_load_invoked(50.0, NEMUnitState(10.0, 4))
        @test !fixed_load_invoked(50.0, NEMUnitState(10.0, 2))
        @test !fixed_load_invoked(NaN, NEMUnitState(10.0, 4))
        @test !fixed_load_invoked(0.0, NEMUnitState(10.0, 4))
        @test effective_fixed_load(50.0, NEMUnitState(10.0, 4)) == 50.0
        @test effective_fixed_load(50.0, NEMUnitState(10.0, 1)) == 0.0
        @test effective_fixed_load(NaN, NEMUnitState(10.0, 4)) == 0.0
    end

    @testset "FCAS enablement and joint ramping move with Initial MW" begin
        # AEMO FCAS Model in NEMDE §5: the offer is enabled only while the unit is inside the
        # enablement span, and a storage device's span is checked against its net output.
        span = FCASTrapezium(;
            enablement_min = 0.0, low_breakpoint = 10.0, high_breakpoint = 90.0, enablement_max = 100.0,
            max_avail = 100.0,
        )
        @test fcas_state_stranded_ok(span, NEMUnitState(50.0, 4))
        @test !fcas_state_stranded_ok(span, NEMUnitState(150.0, 4))
        @test fcas_state_stranded_ok(span, NEMUnitState(-50.0, 4))
        @test !fcas_state_stranded_ok(span, NEMUnitState(-50.0, 4); storage = true)
        # An unknown starting output fails the pre-condition rather than passing it.
        @test !fcas_state_stranded_ok(span, NEMUnitState(NaN, 4))
        @test !fcas_state_stranded_ok(span, NEMUnitState(NaN, 4); storage = true)
        # §6.1: the upper joint limit is Initial MW plus the AGC capability, the lower minus it.
        state = NEMUnitState(50.0, 4)
        raised = NEMUnitState(80.0, 4)
        @test fcas_ramping_limit(10.0, true, state) == 60.0
        @test fcas_ramping_limit(10.0, false, state) == 40.0
        @test fcas_ramping_limit(10.0, true, raised) > fcas_ramping_limit(10.0, true, state)
        @test fcas_ramping_limit(10.0, false, raised) > fcas_ramping_limit(10.0, false, state)
        # A zero or absent capability, or an unknown start, deactivates the ramping row.
        @test fcas_ramping_active(10.0, state)
        @test !fcas_ramping_active(0.0, state)
        @test !fcas_ramping_active(NaN, state)
        @test !fcas_ramping_active(10.0, NEMUnitState(NaN, 4))
        # AEMO FCAS Model in NEMDE footnote 11: a fast-start unit starting in modes 0, 1 or 2 is
        # exempt from joint ramping; any other unit is not.
        @test fcas_joint_ramping_exempt(NEMUnitState(50.0, 0), true)
        @test fcas_joint_ramping_exempt(NEMUnitState(50.0, 1), true)
        @test fcas_joint_ramping_exempt(NEMUnitState(50.0, 2), true)
        @test !fcas_joint_ramping_exempt(NEMUnitState(50.0, 3), true)
        @test !fcas_joint_ramping_exempt(NEMUnitState(50.0, 4), true)
        @test !fcas_joint_ramping_exempt(NEMUnitState(50.0, 0), false)
        # A bidirectional unit's two regulation sides are gated together while both pass their
        # other pre-conditions.
        gen = FCASTrapezium(;
            enablement_min = 20.0, low_breakpoint = 30.0, high_breakpoint = 80.0, enablement_max = 100.0,
            max_avail = 100.0,
        )
        load = FCASTrapezium(;
            enablement_min = -100.0, low_breakpoint = -80.0, high_breakpoint = -30.0, enablement_max = -20.0,
            max_avail = 100.0,
        )
        @test fcas_both_sides_stranded_ok(gen, load, true, true, NEMUnitState(0.0, 4)) == (true, true)
        @test fcas_both_sides_stranded_ok(gen, load, true, true, NEMUnitState(110.0, 4)) == (false, false)
        @test fcas_both_sides_stranded_ok(gen, load, true, false, NEMUnitState(50.0, 4)) == (true, false)
        @test fcas_both_sides_stranded_ok(gen, load, true, true, NEMUnitState(NaN, 4)) == (false, false)
    end

    @testset "the MNSP flow envelope starts from the metered flow" begin
        @test mnsp_ramp_envelope(100.0, 2.0, 3.0, 5.0) == (110.0, 85.0)
        @test mnsp_ramp_envelope(-50.0, 0.0, 0.0, 5.0) == (-50.0, -50.0)
        upper, lower = mnsp_ramp_envelope(0.0, 2.0, 3.0, 5.0)
        @test (upper, lower) == (10.0, -15.0)
        @test isnan(first(mnsp_ramp_envelope(NaN, 2.0, 3.0, 5.0)))
    end

    @testset "the composite ramp rate clears a unit across zero" begin
        # AEMO Dispatch Procedure Appendix C: a scheduled bidirectional unit that may move from
        # consumption to generation inside the interval ramps at a rate blending both sides' bids.
        # (a) Wholly on the generation side, and wholly on the load side, the starting side's own
        # rates stand: up from the load side is its ramp-down rate, down is its ramp-up rate.
        @test composite_ramp_rates(3.0, 4.0, 5.0, 6.0, 5.0, NEMUnitState(50.0, 4)) == (3.0, 4.0)
        @test composite_ramp_rates(3.0, 4.0, 5.0, 6.0, 5.0, NEMUnitState(-50.0, 4)) == (6.0, 5.0)
        # (b) AEMO's worked example: Initial MW -10, load ramp down 5 MW/min and generation ramp up
        # 3 MW/min over five minutes give 3.8 MW/min, from -10 MW to 9 MW.
        up, _ = composite_ramp_rates(3.0, 4.0, 5.0, 5.0, 5.0, NEMUnitState(-10.0, 4))
        @test up ≈ 3.8
        # The mirror from 10 MW: generation ramp down 3 MW/min and load ramp up 5 MW/min.
        _, down = composite_ramp_rates(3.0, 3.0, 5.0, 6.0, 5.0, NEMUnitState(10.0, 4))
        @test down ≈ 11 / 3
        # (c) A battery with both sides bid at -10 MW blends the load ramp down with the generation
        # ramp up, while its down rate is the load ramp up.
        up, down = composite_ramp_rates(3.0, 4.0, 5.0, 6.0, 5.0, NEMUnitState(-10.0, 4))
        @test up ≈ 4.0
        @test down == 5.0
        # A unit that bids one side only keeps that side's rates on the net-generation axis: a
        # load-only unit's up rate is its ramp down and its down rate its ramp up.
        @test composite_ramp_rates(2.0, 3.0, NaN, NaN, 5.0, NEMUnitState(-10.0, 4)) == (2.0, 3.0)
        @test composite_ramp_rates(NaN, NaN, 2.0, 3.0, 5.0, NEMUnitState(-10.0, 4)) == (3.0, 2.0)
        @test first(composite_ramp_rates(3.0, 4.0, 5.0, 0.0, 5.0, NEMUnitState(-10.0, 4))) == 0.0
    end

    @testset "the build writes only the first-solve seeds of the state-dependent parameters" begin
        sys = replay_system()
        base = get_base_power(sys)
        source = AEMSim._state_source()
        seen = 0
        for device in nem_dispatch_devices(sys)
            @test !has_time_series(device, SingleTimeSeries, NEM_SERIES.max_active_power)
            @test !has_time_series(device, SingleTimeSeries, NEM_SERIES.fixed_load)
            @test !has_time_series(device, SingleTimeSeries, NEM_SERIES.fixed_load_invoked)
            observed = AustralianElectricityMarkets.get_observed_state(device)
            observed.initial_mw isa PowerSystems.IS.TimeSeriesKey || continue
            seen += 1
            stamps = PSY.get_time_series_timestamps(SingleTimeSeries, device, AEMSim._INITIAL_MW_SEED_SERIES)
            expected = [unit_state(source, device, t).initial_mw for t in stamps]
            @test values_of(device, AEMSim._INITIAL_MW_SEED_SERIES) ≈ expected
            if AEMSim._has_fixed_load_bid(device)
                steps = [AEMSim._fixed_load_step(device, t; source) for t in stamps]
                @test values_of(device, AEMSim._FIXED_LOAD_SEED_SERIES) ≈ [step.target / base for step in steps]
                @test values_of(device, AEMSim._FIXED_LOAD_INVOKED_SEED_SERIES) == [step.invoked ? 1.0 : 0.0 for step in steps]
            else
                @test !has_time_series(device, SingleTimeSeries, AEMSim._FIXED_LOAD_SEED_SERIES)
            end
        end
        @test seen > 0
    end

    @testset "the FCAS joint ramping limit with the observed state equals the written series" begin
        sys = replay_system()
        base = get_base_power(sys)
        with_units_base(sys, "NATURAL_UNITS") do
            for device in nem_dispatch_devices(sys)
                for service in (BidType.RAISEREG, BidType.LOWERREG)
                    name = fcas_ramping_series_name(service)
                    has_time_series(device, SingleTimeSeries, name) || continue
                    stamps = PSY.get_time_series_timestamps(SingleTimeSeries, device, name)
                    window = AEMSim._FCASWindow(first(stamps), length(stamps), resolution)
                    caps = AEMSim._fcas_agc_ramp_caps(window, device, AEMSim._fcas_ramp_rate_service(device, service))
                    # The writer's own enablement mask is the non-state half of its ramping rule.
                    enabled = AEMSim._fcas_regulation_enabled_mask(window, device, service, fcas_bid_direction(device, service))
                    fast_start = AEMSim._fcas_fast_start_flags(window, device)
                    upper = service == fcas_upper_regulation_service(device)
                    written = [entry[1] * base for entry in values_of(device, name)]
                    for i in eachindex(stamps)
                        state = unit_state(ObservedState(), device, stamps[i])
                        limit = written[i]
                        if fcas_ramping_active(caps[i], state) && enabled[i] && !fcas_joint_ramping_exempt(state, fast_start[i])
                            @test fcas_ramping_limit(caps[i], upper, state) ≈ limit rtol = 1.0e-12
                        else
                            @test limit ≈ (upper ? FCAS_INACTIVE_LIMIT_MW : -FCAS_INACTIVE_LIMIT_MW)
                        end
                    end
                end
            end
        end
    end

    @testset "FCAS enablement with the observed state equals the written masks" begin
        sys = replay_system()
        # The §5 pre-conditions of one side other than the stranded one, per interval of `window`.
        function preconditions(window, device, service, decremental)
            (; trapeziums, curves) = AEMSim._fcas_offer(window, device, service, offer_side(decremental))
            availability, agc_status = AEMSim._fcas_scaling_inputs(window, device)
            regulation = service in AustralianElectricityMarkets.FCAS_REGULATION_MARKETS
            return map(1:window.horizon) do t
                AEMSim._fcas_preconditions(
                    device, regulation, decremental, trapeziums[t], curves[t], availability(t), agc_status(t),
                )
            end
        end
        with_units_base(sys, "NATURAL_UNITS") do
            for device in nem_dispatch_devices(sys)
                inputs = only(PSY.get_supplemental_attributes(NEMDispatchInputs, device))
                for service in unique(entry.service for entry in inputs.fcas)
                    direction = fcas_bid_direction(device, service)
                    decremental = direction == FCASBidDirection.DECREMENTAL
                    trapezium_name = AustralianElectricityMarkets.bid_series_name(
                        service, :trapezium, decremental ? AustralianElectricityMarkets.BidDirection.LOAD : AustralianElectricityMarkets.BidDirection.GEN,
                    )
                    stamps = PSY.get_time_series_timestamps(SingleTimeSeries, device, trapezium_name)
                    window = AEMSim._FCASWindow(first(stamps), length(stamps), resolution)
                    states = [unit_state(ObservedState(), device, t) for t in stamps]
                    active(dec) = Bool[entry[1] > 0.0 for entry in values_of(device, fcas_effective_series_name(service, dec))]
                    if direction == FCASBidDirection.BOTH
                        gen_traps = AEMSim._fcas_offer(window, device, service, OfferSide.GEN).trapeziums
                        load_traps = AEMSim._fcas_offer(window, device, service, OfferSide.LOAD).trapeziums
                        gen_ok = preconditions(window, device, service, false)
                        load_ok = preconditions(window, device, service, true)
                        derived = [
                            fcas_both_sides_stranded_ok(gen_traps[i], load_traps[i], gen_ok[i], load_ok[i], states[i])
                                for i in eachindex(states)
                        ]
                        @test [flag[1] for flag in derived] == active(false)
                        @test [flag[2] for flag in derived] == active(true)
                    else
                        traps = AEMSim._fcas_offer(window, device, service, offer_side(decremental)).trapeziums
                        ok = preconditions(window, device, service, decremental)
                        derived = [
                            ok[i] && fcas_state_stranded_ok(traps[i], states[i]; storage = device isa Storage)
                                for i in eachindex(states)
                        ]
                        @test derived == active(decremental)
                    end
                end
            end
        end
    end
end


@testset "FCAS offers point at the bid series" begin
    AEM = AustralianElectricityMarkets
    replay_db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    sys = nem_system(replay_db, NEMDEConfiguration(); date_range = interval)
    set_effective_offers!(sys)
    fcas_inputs(device) = only(get_supplemental_attributes(NEMDispatchInputs, device)).fcas
    bw01 = get_component(EnergyReservoirStorage, sys, "BW01")
    bid = only(
        b for b in AEM.get_fcas_bids(AEM._nem_offer_cost(bw01))
            if b.service == BidType.RAISEREG && AEM._fcas_bid_side(bw01, b) == OfferSide.GEN
    )
    entry = only(i for i in fcas_inputs(bw01) if i.service == BidType.RAISEREG && i.side == OfferSide.GEN)
    @test entry.offer == bid.offer_curves
    @test !has_time_series(bw01, SingleTimeSeries, fcas_series_name("fcas_offer", BidType.RAISEREG, false))
    # Removes BW01's RAISEREG service, so its bid is unmodelled, and derives the offers again.
    raisereg = only(s for s in PSY.get_services(bw01) if s isa FCASService && AEM.get_bid_type(s) == BidType.RAISEREG)
    PSY.remove_service!(bw01, raisereg)
    set_effective_offers!(sys)
    checked = 0
    for device in AEM.nem_dispatch_devices(sys)
        cost = AEM._nem_offer_cost(device)
        isnothing(cost) && continue
        for bid in AEM.get_fcas_bids(cost)
            isempty(AEM._fcas_services(device, bid.service)) || continue
            checked += 1
            @test all(i -> i.service != bid.service || isnothing(i.offer), fcas_inputs(device))
        end
    end
    @test checked > 0
end
