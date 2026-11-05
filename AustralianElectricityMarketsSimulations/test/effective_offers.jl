# Effective FCAS offers and tie-break scales, derived by `set_effective_offers!` (run by `prepare_replay!`),
# and the accessors that read the derived inputs.

@testset "Effective offers" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))

    @testset "set_effective_offers! skips an unavailable unpriced device, not an available one" begin
        sys = first(nem_network(db))
        set_fcas_bids!(sys, db, date_range)
        set_market_bids!(sys, db, date_range)
        set_fcas_service_bids!(sys, db, date_range)
        gen = first(g for g in get_components(Generator, sys) if has_time_series(g, SingleTimeSeries, "fcas_trapezium_RAISE6SEC"))
        # Drop the generator's offer curve to model a data gap in an available device.
        remove_time_series!(sys, SingleTimeSeries, gen, fcas_offer_series_name(fcas_service(gen, BidType.RAISE6SEC), false))
        @test get_available(gen)
        # Available devices without their curve are a real data gap, so the derivation still throws.
        @test_throws ArgumentError set_effective_offers!(sys)
        # Each contributing offer lacking its curve, found by the same rule the derivation uses.
        unpriced = Set{String}()
        for svc in get_components(FCASService, sys), device in get_contributing_devices(sys, svc)
            bid_type = get_bid_type(svc)
            for dec in fcas_offer_sides(fcas_bid_direction(device, bid_type))
                has_time_series(device, SingleTimeSeries, fcas_offer_series_name(svc, dec)) || push!(unpriced, get_name(device))
            end
        end
        @test get_name(gen) in unpriced
        for name in unpriced
            device = first(d for d in get_components(Device, sys) if get_name(d) == name)
            set_available!(device, false)
        end
        set_effective_offers!(sys)
        @test !has_time_series(gen, SingleTimeSeries, fcas_effective_series_name(BidType.RAISE6SEC, false))
    end

    @testset "get_fcas_offer reads the scaled trapezium and the offer curve" begin
        sys = first(nem_network(db))
        set_fcas_bids!(sys, db, date_range)
        set_market_bids!(sys, db, date_range)
        set_fcas_service_bids!(sys, db, date_range)
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
            add_time_series!(sys, gen, AustralianElectricityMarkets.single_series("energy_max_avail", start, fill(1.0, 2), Minute(5)))
            set_energy_offer!(sys, gen, OfferSide.GEN, AustralianElectricityMarkets.single_series("energy_offer", start, fill(curve, 2), Minute(5)))
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
    truth = read_fcas_scaling_inputs(db, date_range)

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
        set_fcas_scaling_inputs!(sys, rates_db, date_range)
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
        set_fcas_scaling_inputs!(sys, rates_db, date_range)
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
        set_fcas_bids!(sys, db, date_range; resolution = resolution)

        device = get_component(NEMThermalGen, sys, "ER01")
        full_grid = collect(date_range)[1:(end - 1)]
        horizon = length(full_grid)
        # 60 MW/h is a 5 MW AGC ramping capability over 5 minutes.
        by_time = Dict(t => (RAMPUPRATE = (t == full_grid[1] ? missing : 60.0),) for t in full_grid)
        AustralianElectricityMarkets._attach_fcas_scaling_series!(
            sys, device, by_time, full_grid, :RAMPUPRATE, "fcas_agc_ramp_rate_RAISEREG", base_power,
        )

        raw, scaled = with_units_base(sys, "NATURAL_UNITS") do
            (
                AustralianElectricityMarkets._get_fcas_trapezium(device, BidType.RAISEREG, start_date, horizon),
                get_scaled_fcas_trapezium(device, BidType.RAISEREG, start_date, horizon),
            )
        end
        @test get_max_avail(raw[1]) > 5.0
        @test isequal(Tuple(scaled[1]), Tuple(raw[1]))
        @test all(i -> isapprox(get_max_avail(scaled[i]), min(get_max_avail(raw[i]), 5.0)), 2:horizon)
    end

    @testset "get_scaled_fcas_trapezium narrows the trapezium wherever the AGC input is more restrictive" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_fcas_bids!(sys, db, date_range; resolution = resolution)
        set_fcas_scaling_inputs!(sys, db, date_range)

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
    scaling_truth = read_fcas_scaling_inputs(db, date_range)

    @testset "energy offer views and MAXAVAIL per direction" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range)
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
        set_energy_offer!(
            sys, stock, OfferSide.GEN,
            AustralianElectricityMarkets.single_series("energy_offer", start, fill(PiecewiseStepData([0.0, 5.0], [10.0]), 2), Minute(5)),
        )
        @test isnothing(get_energy_offer(stock, OfferSide.GEN))
        @test isnothing(get_energy_offer(stock, OfferSide.LOAD))
    end

    @testset "offer views of each side after set_market_bids!" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range)
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
        set_market_bids!(sys, db, second_range)
        for device in vcat(collect(get_components(NEMThermalGen, sys)), collect(get_components(NEMStorage, sys)))
            get_available(device) || continue
            for side in [b.side for b in AustralianElectricityMarkets.get_energy_bids(get_operation_cost(device))]
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
        set_fcas_scaling_inputs!(sys, db, date_range)
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
        by_time = Dict(t => (AGCSTATUS = (t == full_grid[1] ? missing : 1.0),) for t in full_grid)
        AustralianElectricityMarkets._attach_fcas_scaling_series!(
            sys, device, by_time, full_grid, :AGCSTATUS, "fcas_agc_status", 1.0,
        )
        status = get_fcas_agc_status(device, start_date, length(full_grid))
        @test isnothing(status[1])
        @test all(==(1), status[2:end])
    end
end
