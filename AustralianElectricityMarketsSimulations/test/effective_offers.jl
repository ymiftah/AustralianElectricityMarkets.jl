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


@testset "a device with no dispatch rows before its registration does not abort the replay" begin
    # BW02 registers after 00:10, so both steps precede its registration and must read the zero seed state
    # (zero output, no fixed loading) instead of throwing on the absent dispatch mode.
    steps = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 10)
    late_hive = registered_from(AEM_TEST_REPLAY_HIVE_DIR, "BW02", "2025-01-01 00:10:00")
    late = nem_system(
        aem_connect(HiveConfiguration(hive_location = late_hive, filesystem = "file")), NEMDEConfiguration();
        date_range = first(steps):Minute(5):(last(steps) + 2Minute(5)),
    )
    out = run_replay(late, steps)
    @test length(PSI.read_optimizer_stats(out.results).objective_value) == length(steps)
    container = PSI.get_optimization_container(out.model)
    for P in (AEMS.InitialPowerTimeSeriesParameter, AEMS.FixedLoadTimeSeriesParameter, AEMS.FixedLoadInvokedTimeSeriesParameter)
        @test only(PSI.get_parameter_column_values(PSI.get_parameter(container, PSI.ParameterKey(P, HydroDispatch)), "BW02")) === 0.0
    end
    # The observed state at a stamp before registration is the zero state, not an absent dispatch mode.
    bw02 = get_component(HydroDispatch, PSI.get_system(out.model), "BW02")
    @test only(AustralianElectricityMarkets.observed_unit_states(bw02, [last(steps)])) == AustralianElectricityMarkets.NEMUnitState(0.0, 0)
end


@testset "Dispatch-limit pre-flight" begin
    AEM = AustralianElectricityMarkets
    AEMSim = AustralianElectricityMarketsSimulations
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    sys_base, _ = nem_network(db)
    resolution = Minute(5)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:resolution:(start_date + Hour(2))
    max_avail = bid_series_name(BidType.ENERGY, :max_avail, AEM.BidDirection.GEN)

    function built()
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_available!(get_component(ThermalStandard, sys, "ER02"), false)
        set_available!(get_component(HydroDispatch, sys, "BW02"), false)
        set_unit_conditions!(sys, db, date_range)
        AEM._set_replay_inputs!(sys)
        return sys
    end

    @testset "a complete build passes, a non-scheduled load without an energy bid included" begin
        sys = built()
        @test AEMSim._has_nem_dispatch_limits(get_component(ThermalStandard, sys, "ER01"))
        @test AEMSim._has_nem_dispatch_limits(get_component(InterruptiblePowerLoad, sys, "ASLOAD1"))
        semi = first(d for d in get_components(RenewableDispatch, sys) if is_semi_scheduled(d))
        @test PSI.get_multiplier_value(EnergyLimitTimeSeriesParameter(), semi, NEMReplayDispatch()) ≈ 1 / get_base_power(sys)
    end

    @testset "a missing $name series fails the pre-flight" for name in (max_avail, NEM_SERIES.ramp_up_rate)
        sys = built()
        device = get_component(ThermalStandard, sys, "ER01")
        remove_series_and_forecast!(sys, device, name)
        @test !AEMSim._has_nem_dispatch_limits(device)
    end

    @testset "the observed initial MW key names the series the pre-flight requires" begin
        sys = built()
        device = get_component(ThermalStandard, sys, "ER01")
        observed = AEM.get_observed_state(device)
        values = get_time_series_values(SingleTimeSeries, device, get_name(observed.initial_mw); ignore_scaling_factors = true)
        add_time_series!(sys, device, single_series("other_initial", start_date, values, resolution))
        AEM.set_observed_state!(
            device,
            AEM.NEMObservedState(; initial_mw = AEM._series_key(device, "other_initial"), dispatch_mode = observed.dispatch_mode),
        )
        # The default name is only a convenience: the re-keyed series is the one required.
        remove_series_and_forecast!(sys, device, "observed_initial_mw")
        @test AEMSim._has_nem_dispatch_limits(device)
        @test isnothing(AEMSim._check_state_series_alignment(device))
        PSY.remove_time_series!(sys, SingleTimeSeries, device, "other_initial")
        @test !AEMSim._has_nem_dispatch_limits(device)
    end
end


@testset "AEM derivation kernels" begin
    AEM = AustralianElectricityMarkets
    Δ = interval_hours(Minute(5))

    @testset "effective_energy_availability limits MAXAVAIL by UIGF and zeroes the excluded intervals" begin
        @test AEM.effective_energy_availability([10.0, 10.0], [8.0, 12.0], [60.0, 60.0], false) == [8.0, 10.0]
        @test AEM.effective_energy_availability([10.0, 10.0], nothing, [60.0, 60.0], false) == [10.0, 10.0]
        @test AEM.effective_energy_availability([10.0, 10.0], nothing, [60.0, NaN], false) == [10.0, 0.0]
        @test AEM.effective_energy_availability([10.0, 10.0], [8.0, 8.0], [60.0, 60.0], true) == [0.0, 0.0]
    end

    @testset "a device with no FCAS bid gets no FCAS effective series" begin
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], [60.0, 80.0],
        )
        cheap = get_component(ThermalStandard, sys, TOY_CHEAP)
        @test isempty(get_fcas_bids(AEM._nem_offer_cost(cheap)))
        @test !any(startswith("fcas_effective_"), [get_name(k) for k in get_time_series_keys(cheap)])
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
        @test mnsp_ramp_envelope(0.0, 2.0, 3.0, 5.0) == (10.0, -15.0)
        @test isnan(first(mnsp_ramp_envelope(NaN, 2.0, 3.0, 5.0)))
    end

    @testset "the composite ramp rate clears a unit across zero" begin
        # Wholly on one side the starting side's own rates stand: from the load side, up is its ramp-down rate.
        @test composite_ramp_rates(3.0, 4.0, 5.0, 6.0, 5.0, NEMUnitState(50.0, 4)) == (3.0, 4.0)
        @test composite_ramp_rates(3.0, 4.0, 5.0, 6.0, 5.0, NEMUnitState(-50.0, 4)) == (6.0, 5.0)
        # AEMO Dispatch Procedure Appendix C worked example: Initial MW -10, load ramp down 5 MW/min and
        # generation ramp up 3 MW/min over five minutes give 3.8 MW/min, from -10 MW to 9 MW.
        up, _ = composite_ramp_rates(3.0, 4.0, 5.0, 5.0, 5.0, NEMUnitState(-10.0, 4))
        @test up ≈ 3.8
        # The mirror from 10 MW: generation ramp down 3 MW/min and load ramp up 5 MW/min.
        _, down = composite_ramp_rates(3.0, 3.0, 5.0, 6.0, 5.0, NEMUnitState(10.0, 4))
        @test down ≈ 11 / 3
        # A battery with both sides bid at -10 MW blends the load ramp down with the generation ramp up,
        # while its down rate is the load ramp up.
        @test all(composite_ramp_rates(3.0, 4.0, 5.0, 6.0, 5.0, NEMUnitState(-10.0, 4)) .≈ (4.0, 5.0))
        # A unit that bids one side only keeps that side's rates on the net-generation axis.
        @test composite_ramp_rates(2.0, 3.0, NaN, NaN, 5.0, NEMUnitState(-10.0, 4)) == (2.0, 3.0)
        @test composite_ramp_rates(NaN, NaN, 2.0, 3.0, 5.0, NEMUnitState(-10.0, 4)) == (3.0, 2.0)
        @test first(composite_ramp_rates(3.0, 4.0, 5.0, 0.0, 5.0, NEMUnitState(-10.0, 4))) == 0.0
    end
end
