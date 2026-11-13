# The replay-unit offers and limits that AustralianElectricityMarketsSimulations reads, with the
# `_set_replay_inputs!` series they are derived from.

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

    @testset "initial_mw reads back as DISPATCHLOAD, and availability is the bid MAXAVAIL" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range)
        attach_dispatch_limits!(sys, db, date_range)
        AustralianElectricityMarkets._set_replay_inputs!(sys)
        set_available!(get_component(ThermalStandard, sys, "ER02"), false)
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


@testset "Derived availability: zero branches and the MAXAVAIL branch" begin
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
            @test AEMSim._availability_series_name(er01, EnergyLimitTimeSeriesParameter) == bid_series_name(BidType.ENERGY, :max_avail, BD.GEN)
        end
    end

    @testset "a non-scheduled load without an energy bid reads zero availability from the zero MAXAVAIL series" begin
        sys = built()
        asload = get_component(InterruptiblePowerLoad, sys, "ASLOAD1")
        @test isempty(AustralianElectricityMarkets.get_energy_bids(AustralianElectricityMarkets._nem_offer_cost(asload)))
        name = bid_series_name(BidType.ENERGY, :max_avail, AustralianElectricityMarkets.BidDirection.LOAD)
        @test AEMSim._availability_series_name(asload, EnergyLimitTimeSeriesParameter) == name
        @test all(==(0.0), get_time_series_values(SingleTimeSeries, asload, name; ignore_scaling_factors = true))
        @test AEMSim._has_nem_dispatch_limits(asload)
    end

    @testset "a missing registered MAXAVAIL series fails the pre-flight" begin
        sys = built()
        device = get_component(ThermalStandard, sys, "ER01")
        @test AEMSim._has_nem_dispatch_limits(device)
        name = bid_series_name(BidType.ENERGY, :max_avail, AustralianElectricityMarkets.BidDirection.GEN)
        remove_series_and_forecast!(sys, device, name)
        @test !AEMSim._has_nem_dispatch_limits(device)
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
        remove_series_and_forecast!(sys, device, "observed_initial_mw")
        @test AEMSim._has_nem_dispatch_limits(device)
        @test isnothing(AEMSim._check_state_series_alignment(device))
    end

    @testset "a missing ramp-up series fails the pre-flight" begin
        sys = built()
        device = get_component(ThermalStandard, sys, "ER01")
        @test AEMSim._has_nem_dispatch_limits(device)
        remove_series_and_forecast!(sys, device, NEM_SERIES.ramp_up_rate)
        @test !AEMSim._has_nem_dispatch_limits(device)
    end
end


@testset "State-independent derivation: pure functions and the written series" begin
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

    @testset "a device with no FCAS bid gets no FCAS effective series" begin
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], [60.0, 80.0],
        )
        cheap = get_component(ThermalStandard, sys, TOY_CHEAP)
        @test isempty(get_fcas_bids(AustralianElectricityMarkets._nem_offer_cost(cheap)))
        @test !any(startswith("fcas_effective_"), [get_name(k) for k in get_time_series_keys(cheap)])
    end

    @testset "the UIGF parameter reads the telemetry UIGF per unit of the base" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_unit_conditions!(sys, db, date_range)
        AustralianElectricityMarkets._set_replay_inputs!(sys)
        semi = first(d for d in get_components(RenewableDispatch, sys) if is_semi_scheduled(d))
        @test has_time_series(semi, SingleTimeSeries, NEM_TELEMETRY_SERIES.uigf)
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
        return nem_system(replay_db, NEMDEConfiguration(); date_range = interval)
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
