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
        @test first(values_of(er01, AustralianElectricityMarkets.bid_series_name(BidType.ENERGY, :max_avail, AustralianElectricityMarkets.BidDirection.GEN))) ≈ 1.01 * get_base_power(sys)
        @test PowerSystems.get_y_coords(first(values_of(bw01, "energy_offer_decremental"))) == prices_descending
        @test first(values_of(bw01, AustralianElectricityMarkets.bid_series_name(BidType.ENERGY, :max_avail, AustralianElectricityMarkets.BidDirection.LOAD))) ≈ 1.01 * get_base_power(sys)
        @test PowerSystems.get_y_coords(first(values_of(bw01, AustralianElectricityMarkets._fcas_offer_series_name(bw01, BidType.RAISEREG, false)))) == prices_ascending
        @test PowerSystems.get_y_coords(first(values_of(asload1, AustralianElectricityMarkets._fcas_offer_series_name(asload1, BidType.RAISE6SEC, true)))) == prices_descending
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
            # A static observed state keeps the observed-state series out of these offer fixtures.
            AustralianElectricityMarkets.set_observed_state!(
                gen, AustralianElectricityMarkets.NEMObservedState(; initial_mw = 0.0, dispatch_mode = 0),
            )
            _toy_energy_bid!(sys, gen, AustralianElectricityMarkets.BidDirection.GEN, [start, start + Minute(5)], fill(curve, 2), fill(PSY.get_base_power(sys), 2))
        end
        AustralianElectricityMarkets._set_replay_inputs!(sys)

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
        # the EnergyTieBreak service below is still attached by nem_system.
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
        @test only(AustralianElectricityMarkets.observed_unit_states(bw02, [last(steps)])) == AustralianElectricityMarkets.NEMUnitState(0.0, 0)
    end
end


@testset "Accessors of offers and dispatch limits" begin
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
        AustralianElectricityMarkets._set_replay_inputs!(sys)
        set_effective_offers!(sys)
        for bat in get_components(EnergyReservoirStorage, sys)
            gen_offer, load_offer = get_energy_offer(bat, OfferSide.GEN), get_energy_offer(bat, OfferSide.LOAD)
            ta_gen = get_time_series_array(SingleTimeSeries, bat, "energy_offer")
            ta_load = get_time_series_array(SingleTimeSeries, bat, "energy_offer_decremental")
            @test gen_offer.side == OfferSide.GEN && load_offer.side == OfferSide.LOAD
            @test gen_offer.timestamps == PowerSystems.TimeSeries.timestamp(ta_gen) && gen_offer.curves == values(ta_gen)
            @test load_offer.curves == values(ta_load)
        end
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
        AustralianElectricityMarkets._set_replay_inputs!(sys)
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

    @testset "a second set_market_bids! replaces the bid series timestamps" begin
        sys = deepcopy(sys_base)
        second_range = (start_date + Minute(30)):Minute(5):(start_date + Minute(90))
        set_market_bids!(sys, db, date_range)
        set_unit_conditions!(sys, db, date_range)
        set_market_bids!(sys, db, second_range)
        for device in vcat(collect(get_components(ThermalStandard, sys)), collect(get_components(EnergyReservoirStorage, sys)))
            get_available(device) || continue
            for bid in AustralianElectricityMarkets.get_energy_bids(AustralianElectricityMarkets._nem_offer_cost(device))
                name = bid_series_name(BidType.ENERGY, :offer_curves, bid.direction)
                @test first(get_time_series_timestamps(SingleTimeSeries, device, name)) == second_range[1]
            end
        end
    end

    @testset "initial_mw reads back as DISPATCHLOAD, and availability is the bid MAXAVAIL" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range)
        attach_dispatch_limits!(sys, db, date_range)
        AustralianElectricityMarkets._set_replay_inputs!(sys)
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
        end
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
        AustralianElectricityMarkets._set_replay_inputs!(sys)
        set_effective_offers!(sys)
        return sys
    end

    @testset "a non-scheduled load has zero availability and no dispatch-limit series" begin
        sys = built()
        asload = get_component(InterruptiblePowerLoad, sys, "ASLOAD1")
        @test AustralianElectricityMarkets.is_non_scheduled_load(asload)
        # The upper limit is the formulation's row, so the build writes no max_active_power series.
        @test !has_time_series(asload, SingleTimeSeries, NEM_SERIES.max_active_power)
    end

    @testset "energy availability is read from the bid MAXAVAIL" begin
        sys = built()
        BD = AustralianElectricityMarkets.BidDirection
        with_units_base(sys, "NATURAL_UNITS") do
            er01 = get_component(ThermalStandard, sys, "ER01")
            @test !has_time_series(er01, SingleTimeSeries, "energy_availability")
            inputs = only(PSY.get_supplemental_attributes(NEMDispatchInputs, er01))
            @test get_name(inputs.energy_availability) == bid_series_name(BidType.ENERGY, :max_avail, BD.GEN)
        end
    end

    @testset "a non-scheduled load without an energy bid reads zero availability and keys the zero MAXAVAIL" begin
        sys = built()
        asload = get_component(InterruptiblePowerLoad, sys, "ASLOAD1")
        @test isempty(AustralianElectricityMarkets.get_energy_bids(AustralianElectricityMarkets._nem_offer_cost(asload)))
        inputs = only(PSY.get_supplemental_attributes(NEMDispatchInputs, asload))
        name = bid_series_name(BidType.ENERGY, :max_avail, AustralianElectricityMarkets.BidDirection.LOAD)
        @test get_name(inputs.energy_availability) == name
        @test all(==(0.0), get_time_series_values(SingleTimeSeries, asload, name; ignore_scaling_factors = true))
        @test AEMSim._has_nem_dispatch_limits(asload)
    end

    @testset "an energy availability key off the registered MAXAVAIL name fails the pre-flight" begin
        sys = built()
        device = get_component(ThermalStandard, sys, "ER01")
        @test AEMSim._has_nem_dispatch_limits(device)
        old = only(PSY.get_supplemental_attributes(NEMDispatchInputs, device))
        values = get_time_series_values(SingleTimeSeries, device, get_name(old.energy_availability); ignore_scaling_factors = true)
        add_time_series!(sys, device, single_series("other_availability", start_date, values, resolution))
        fields = Dict(f => getfield(old, f) for f in fieldnames(NEMDispatchInputs))
        fields[:energy_availability] = AustralianElectricityMarkets._series_key(device, "other_availability")
        PSY.remove_supplemental_attribute!(sys, device, old)
        PSY.add_supplemental_attribute!(sys, device, NEMDispatchInputs(; fields...))
        @test_throws r"other_availability" AEMSim._has_nem_dispatch_limits(device)
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

    @testset "effective_energy_availability limits MAXAVAIL by UIGF and zeroes the excluded intervals" begin
        @test AustralianElectricityMarkets.effective_energy_availability([10.0, 10.0], [8.0, 12.0], [60.0, 60.0], false) == [8.0, 10.0]
        @test AustralianElectricityMarkets.effective_energy_availability([10.0, 10.0], nothing, [60.0, 60.0], false) == [10.0, 10.0]
        @test AustralianElectricityMarkets.effective_energy_availability([10.0, 10.0], nothing, [60.0, NaN], false) == [10.0, 0.0]
        @test AustralianElectricityMarkets.effective_energy_availability([10.0, 10.0], [8.0, 8.0], [60.0, 60.0], true) == [0.0, 0.0]
    end

    @testset "effective_regulation_enablement takes the more restrictive of bid and AGC limits" begin
        @test effective_regulation_enablement(20.0, 100.0, 30.0, 90.0) == (30.0, 90.0)
        @test effective_regulation_enablement(20.0, 100.0, 10.0, 120.0) == (20.0, 100.0)
        @test effective_regulation_enablement(20.0, 100.0, nothing, nothing) == (20.0, 100.0)
        @test effective_regulation_enablement(20.0, 100.0, nothing, 0.0) == (20.0, 0.0)
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
        AustralianElectricityMarkets._set_replay_inputs!(sys)
        set_effective_offers!(sys)
        names(device) = [get_name(k) for k in get_time_series_keys(device)]
        for device in get_components(StaticInjection, sys)
            @test !any(startswith("energy_max_avail"), names(device))
        end

        device = get_component(ThermalStandard, sys, "ER01")
        inputs = only(PSY.get_supplemental_attributes(NEMDispatchInputs, device))
        @test get_name(inputs.energy_availability) == bid_series_name(BidType.ENERGY, :max_avail, AustralianElectricityMarkets.BidDirection.GEN)
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

        # The availability the formulation reads is the bid MAXAVAIL, in MW, and no energy_availability series is written.
        bid = only(AustralianElectricityMarkets.get_energy_bids(AustralianElectricityMarkets._nem_offer_cost(device)))
        @test inputs.energy_availability == bid.max_avail
        @test !has_time_series(device, SingleTimeSeries, "energy_availability")

        battery = get_component(EnergyReservoirStorage, sys, "BW01")
        battery_inputs = only(PSY.get_supplemental_attributes(NEMDispatchInputs, battery))
        @test get_name(battery_inputs.energy_availability_decremental) == bid_series_name(BidType.ENERGY, :max_avail, AustralianElectricityMarkets.BidDirection.LOAD)
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
        AustralianElectricityMarkets._set_replay_inputs!(sys)
        set_effective_offers!(sys)
        semi = first(d for d in get_components(RenewableDispatch, sys) if is_semi_scheduled(d))
        inputs = only(PSY.get_supplemental_attributes(NEMDispatchInputs, semi))
        @test get_name(inputs.uigf) == NEM_TELEMETRY_SERIES.uigf
        raw = get_time_series_values(SingleTimeSeries, semi, NEM_TELEMETRY_SERIES.uigf; ignore_scaling_factors = true)
        @test PSI.get_multiplier_value(EnergyLimitTimeSeriesParameter(), semi, NEMReplayDispatch()) ≈ 1 / base_power
        @test length(raw) > 0
    end
end


@testset "State-dependent derivation: pure functions of the unit state" begin
    AEM = AustralianElectricityMarkets
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
