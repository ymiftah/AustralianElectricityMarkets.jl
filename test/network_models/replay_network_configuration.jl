@testset "Replay requirements include mandatory MNSP metering" begin
    @test :DISPATCHINTERCONNECTORRES in table_requirements(NEMDEConfiguration())
end

@testset "every NEM device of the network carries its registration" begin
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    as_of, through = first(interval), last(interval) - Minute(5)
    sys, units = nem_network(db; as_of, through)
    units_by_duid = Dict(String(r.DUID) => r for r in eachrow(units))
    factors = Dict(String(r.DUID) => r for r in eachrow(read_loss_factors(db; as_of, through)))
    schedule_types = Dict(
        "SCHEDULED" => ScheduleType.SCHEDULED, "SEMI-SCHEDULED" => ScheduleType.SEMI_SCHEDULED,
        "NON-SCHEDULED" => ScheduleType.NON_SCHEDULED,
    )
    devices = [d for T in (Generator, ControllableLoad, Storage) for d in get_components(T, sys)]
    @test !isempty(devices)
    for device in devices
        name = get_name(device)
        registration = get_registration(device)
        unit, factor = units_by_duid[name], factors[name]
        @test registration.schedule_type == schedule_types[unit.SCHEDULE_TYPE]
        @test registration.gen_loss_factor == factor.GEN_LOSS_FACTOR
        @test registration.load_loss_factor == factor.LOAD_LOSS_FACTOR
        @test registration.registered_from == unit.REGISTERED_FROM
        @test registration.registered_until == unit.REGISTERED_UNTIL
        for key in ("nem_gen_loss_factor", "nem_load_loss_factor", "nem_semi_scheduled")
            @test !haskey(get_ext(device), key)
        end
    end

    # A device built without a registration fails the build steps that read it, naming it.
    set_registration!(get_component(NEMThermalGen, sys, "ER01"), nothing)
    @test_throws r"ER01 has no registration" set_unit_conditions!(sys, db, interval)
end

@testset "NEMDEConfiguration" begin
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    config = NEMDEConfiguration()
    @test_throws ArgumentError nem_system(db, config; date_range = first(interval):Minute(10):last(interval))
    @test_throws ArgumentError nem_system(db, config; date_range = first(interval):Minute(5):first(interval))
    sys = nem_system(db, config; date_range = interval)
    for T in (Generator, ControllableLoad, Storage), device in get_components(T, sys), key in ("nem_gen_loss_factor", "nem_load_loss_factor", "nem_semi_scheduled")
        @test !haskey(get_ext(device), key)
    end
    gen = get_component(NEMRenewableGen, sys, "BW03")
    @test get_registration(gen).schedule_type == ScheduleType.SEMI_SCHEDULED
    @test get_time_series_values(SingleTimeSeries, gen, "bid_energy_max_avail_gen") ≈ [101.0, 102.0, 103.0]
    @test get_time_series_values(SingleTimeSeries, gen, "telemetry_uigf"; ignore_scaling_factors = true) ≈ [41.0, 42.0, 43.0]
    @test !has_time_series(gen, DeterministicSingleTimeSeries, "bid_energy_max_avail_gen")
    @test !isempty(collect(get_components(FCASService, sys)))
    ic = get_component(AreaInterchange, sys, "IC2")
    @test !isempty(get_supplemental_attributes(AustralianElectricityMarkets.NEMMNSPBid, ic))
    @test isempty(get_supplemental_attributes(AustralianElectricityMarkets.NEMInterconnectorLimits, ic))
    diagnostic = nem_system(db, config; date_range = interval, interval_flow_limits = true)
    @test !isempty(get_supplemental_attributes(AustralianElectricityMarkets.NEMInterconnectorLimits, get_component(AreaInterchange, diagnostic, "IC2")))
    directory = mktempdir()
    on_disk = nem_system(db, config; date_range = interval, time_series_in_memory = false, time_series_directory = directory)
    @test !isempty(readdir(directory))
    @test get_time_series_values(SingleTimeSeries, get_component(NEMRenewableGen, on_disk, "BW03"), "telemetry_uigf"; ignore_scaling_factors = true) ≈ [41.0, 42.0, 43.0]
    physical_db = damaged_cache(
        hive, :DISPATCHLOAD,
        "INSERT INTO input SELECT * REPLACE (1 AS INTERVENTION, INITIALMW + CASE WHEN DUID = 'BW03' THEN 10 ELSE 0 END AS INITIALMW) FROM input WHERE INTERVENTION = 0",
    )
    # The physical run needs its own invoked constraints, as AEMO publishes them.
    physical_db = damaged_cache(
        physical_db.config.hive_location, :DISPATCHCONSTRAINT,
        "INSERT INTO input SELECT * REPLACE (1 AS INTERVENTION) FROM input WHERE INTERVENTION = 0",
    )
    physical = nem_system(physical_db, config; date_range = interval, intervention = 1)
    physical_gen = get_component(NEMRenewableGen, physical, "BW03")
    @test get_time_series_values(SingleTimeSeries, physical_gen, "observed_initial_mw"; ignore_scaling_factors = true) .- get_time_series_values(SingleTimeSeries, gen, "observed_initial_mw"; ignore_scaling_factors = true) ≈ fill(10.0, 3)
    @testset "missing bids and demand cannot remove participants or create zero demand" begin
        interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 15)
        for (table, query, expected) in [
                (:BIDDAYOFFER_D, "DELETE FROM input WHERE BIDTYPE = 'ENERGY' AND DUID = 'BW02'", r"price.*BW02"),
                (:BIDPEROFFER_D, "DELETE FROM input WHERE BIDTYPE = 'ENERGY' AND DUID = 'BW01' AND DIRECTION = 'LOAD'", r"BW01 LOAD"),
                (:BIDPEROFFER_D, "DELETE FROM input WHERE BIDTYPE = 'ENERGY' AND DUID = 'BW02'", r"BW02 GEN"),
                (:DISPATCHREGIONSUM, "DELETE FROM input WHERE REGIONID = 'VIC1'", r"missing regional demand.*VIC1"),
                (:DISPATCHREGIONSUM, "DELETE FROM input WHERE SETTLEMENTDATE = TIMESTAMP '2025-01-01 00:10'", r"missing regional demand"),
            ]
            db = damaged_cache(hive, table, query)
            @test_throws expected nem_system(db, NEMDEConfiguration(); date_range = interval)
        end
    end

    @testset "zero availability does not hide a missing ramping unit's offer" begin
        missing_bids = damaged_cache(hive, :BIDPEROFFER_D, "DELETE FROM input WHERE BIDTYPE = 'ENERGY' AND DUID = 'BW02'")
        db = damaged_cache(missing_bids.config.hive_location, :DISPATCHLOAD, "UPDATE input SET AVAILABILITY = 0 WHERE DUID = 'BW02'")
        interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 15)
        @test_throws r"BW02 GEN" nem_system(db, NEMDEConfiguration(); date_range = interval)
    end

end

@testset "the NEMDE build validates its replay inputs" begin
    AEM = AustralianElectricityMarkets
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)

    @testset "a dispatch device without its typed fields" begin
        sys = nem_system(db, NEMDEConfiguration(); date_range = interval)
        set_telemetry!(get_component(NEMThermalGen, sys, "ER01"), nothing)
        @test_throws r"ER01.*telemetry" AEM._check_nemde_replay_inputs(sys)
    end

    @testset "an MNSP without two directional links" begin
        damaged = damaged_cache(hive, :MNSP_INTERCONNECTOR, "DELETE FROM input WHERE LINKID = 'BLNKVIC'")
        @test_throws r"IC2.*link" nem_system(damaged, NEMDEConfiguration(); date_range = interval)
        # The build rejects the damaged cache itself; the check also guards a hand-edited system.
        sys = nem_system(db, NEMDEConfiguration(); date_range = interval)
        ic2 = get_component(AreaInterchange, sys, "IC2")
        remove_supplemental_attribute!(sys, ic2, first(get_supplemental_attributes(AEM.NEMMNSPLink, ic2)))
        @test_throws r"IC2.*link" AEM._check_nemde_replay_inputs(sys)
    end

    @testset "an invoked constraint without an exact GENCONDATA definition" begin
        damaged = damaged_cache(hive, :GENCONDATA, "DELETE FROM input WHERE GENCONID = 'N_BAYSW_THERMAL'")
        @test_throws r"GENCONID" nem_system(damaged, NEMDEConfiguration(); date_range = interval)
    end

    @testset "fixed-load constraints need no GENCONDATA" begin
        fixed = damaged_cache(hive, :DISPATCHCONSTRAINT, "UPDATE input SET CONSTRAINTID = '\$BW01'")
        fixed = damaged_cache(
            fixed.config.hive_location, :BIDPEROFFER_D,
            "UPDATE input SET FIXEDLOAD = 1.0 WHERE DUID = 'BW01' AND BIDTYPE = 'ENERGY'",
        )
        # Keep the table cached, with no definition of any invoked constraint.
        without_definitions = damaged_cache(
            fixed.config.hive_location, :GENCONDATA, "DELETE FROM input WHERE GENCONID <> 'N_BAYSW_THERMAL'",
        )
        @test nem_system(without_definitions, NEMDEConfiguration(); date_range = interval) isa System
    end

    @testset "exact padded coverage and versions" begin
        t = DateTime(2025, 1, 1, 0, 5)
        sys = nem_system(db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(10)))
        @test isempty(get_skipped_constraints(sys))
        @test isempty(get_defaulted_constraint_weights(sys))
        @test isempty(get_missing_constraint_intervals(sys))
        @test isempty(get_dropped_terms(sys))
    end

    @testset "a built-in zero-flow definition needs no GENCONDATA" begin
        zero = damaged_cache(
            hive, :INTERCONNECTOR,
            "INSERT INTO input SELECT 'V-S-MNSP1' AS INTERCONNECTORID, 'VIC1' AS REGIONFROM, 'SA1' AS REGIONTO, '2025-01' AS archive_month",
        )
        zero = damaged_cache(
            zero.config.hive_location, :INTERCONNECTORCONSTRAINT,
            "INSERT INTO input SELECT 'V-S-MNSP1' AS INTERCONNECTORID, TIMESTAMP '2025-01-01 00:00:00' AS EFFECTIVEDATE, " *
                "1 AS VERSIONNO, 200.0 AS MAXMWIN, 200.0 AS MAXMWOUT, 0.1 AS FROMREGIONLOSSSHARE, 0.01 AS LOSSCONSTANT, " *
                "0.001 AS LOSSFLOWCOEFFICIENT, 'REGULATED' AS ICTYPE, '2025-01' AS archive_month",
        )
        zero = damaged_cache(
            zero.config.hive_location, :DISPATCHCONSTRAINT,
            "UPDATE input SET CONSTRAINTID = 'SVML_ZERO', GENCONID_EFFECTIVEDATE = DATE '2013-08-21', GENCONID_VERSIONNO = 1",
        )
        sys = nem_system(zero, NEMDEConfiguration(); date_range = interval)
        @test isnothing(AEM._check_nemde_replay_inputs(sys))
        @test get_source(get_component(GenericConstraint, sys, "SVML_ZERO@2013-08-21#1")) == "built-in"
    end
end

@testset "Replay shared inputs preserve independent setter results" begin
    AEM = AustralianElectricityMarkets
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    grid = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    shared, units = constrained_system(db; date_range = grid)
    independent, _ = constrained_system(db; date_range = grid)
    @test isequal(units, read_units(db; as_of = first(grid)))
    demand = read_demand(db, grid; resolution = Minute(5))
    demand_before = deepcopy(demand)
    AustralianElectricityMarkets._set_demand!(shared, demand, grid; resolution = Minute(5))
    attach_demand!(independent, db, grid; resolution = Minute(5))
    @test isequal(demand, demand_before)
    for sys in (shared, independent)
        set_market_bids!(sys, db, grid; resolution = Minute(5))
        set_unit_conditions!(sys, db, grid)
    end
    for T in (PowerLoad, NEMThermalGen, NEMHydroGen, NEMRenewableGen, NEMStorage, NEMLoad), component in get_components(T, shared)
        other = get_component(T, independent, get_name(component))
        for key in PowerSystems.get_time_series_keys(component)
            name = get_name(key)
            @test isequal(
                get_time_series_values(SingleTimeSeries, component, name; ignore_scaling_factors = true),
                get_time_series_values(SingleTimeSeries, other, name; ignore_scaling_factors = true),
            )
        end
    end
end

# Whether every numeric term of an operation cost is zero.
_zero_cost_term(::Nothing) = true
_zero_cost_term(x::Real) = iszero(x)
_zero_cost_term(x::NamedTuple) = all(_zero_cost_term, values(x))
_zero_cost_term(x::LinearCurve) = iszero(get_proportional_term(x)) && iszero(get_constant_term(x))
_zero_cost_term(x::CostCurve) = _zero_cost_term(get_value_curve(x)) && _zero_cost_term(get_vom_cost(x))
function _zero_cost_term(cost::PowerSystems.OperationalCost)
    return all(f -> _zero_cost_term(getfield(cost, f)), fieldnames(typeof(cost)))
end

@testset "Stock regional network builds generators with zero operation costs" begin
    AEM = AustralianElectricityMarkets
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    sys, _, _ = AustralianElectricityMarkets.RegionModel._nem_network(db)
    generators = collect(get_components(Generator, sys))
    @test !isempty(generators)
    @test all(g -> get_operation_cost(g) isa Union{RenewableGenerationCost, HydroGenerationCost, ThermalGenerationCost}, generators)
    @test all(g -> _zero_cost_term(get_operation_cost(g)), generators)
    others = [
        d for T in (EnergyReservoirStorage, ControllableLoad) for d in get_components(T, sys)
    ]
    @test !isempty(others)
    @test all(d -> _zero_cost_term(get_operation_cost(d)), others)
end

@testset "replay systems hold only NEM dispatch types" begin
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    sys = nem_system(db, NEMDEConfiguration(); date_range = interval)
    for T in (ThermalStandard, HydroDispatch, RenewableDispatch, EnergyReservoirStorage, InterruptiblePowerLoad)
        @test isempty(get_components(T, sys))
    end
    @test !any(d -> get_operation_cost(d) isa MarketBidCost, Iterators.flatten((get_components(Generator, sys), get_components(Storage, sys), get_components(ControllableLoad, sys))))
    nem_devices = [d for T in (NEMThermalGen, NEMHydroGen, NEMRenewableGen, NEMStorage, NEMLoad) for d in get_components(T, sys)]
    @test !isempty(nem_devices)
    @test all(d -> get_operation_cost(d) isa NEMOfferCost, nem_devices)
    # Every recorded bid key resolves to a series on its device.
    bids = [(d, b) for d in nem_devices for b in AustralianElectricityMarkets.get_energy_bids(get_operation_cost(d))]
    @test !isempty(bids)
    for (device, bid) in bids
        @test has_time_series(device, SingleTimeSeries, bid.offer_curves.name)
        @test has_time_series(device, SingleTimeSeries, bid.max_avail.name)
    end
end

@testset "regional systems keep stock types" begin
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    sys = nem_system(db, RegionalNetworkConfiguration())
    for T in (NEMThermalGen, NEMHydroGen, NEMRenewableGen, NEMStorage, NEMLoad)
        @test isempty(get_components(T, sys))
    end
    @test !isempty(get_components(ThermalStandard, sys))
end

@testset "FCAS bids are recorded without derived offer series" begin
    AEM = AustralianElectricityMarkets
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    grid = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    sys, _ = constrained_system(db; date_range = grid)
    # The formulation's offer series are derived by AEMSim, so AEM attaches none.
    @test !any(
        has_time_series(device, SingleTimeSeries, fcas_offer_series_name(svc, dec))
            for device in get_components(Device, sys), svc in get_components(FCASService, sys), dec in (false, true)
    )
    bidders = [g for g in get_components(Generator, sys) if !isempty(AustralianElectricityMarkets.get_fcas_bids(get_operation_cost(g)))]
    @test !isempty(bidders)
    for g in bidders
        @test get_operation_cost(g) isa NEMOfferCost
        @test has_time_series(g, SingleTimeSeries, AustralianElectricityMarkets.bid_series_name(BidType.RAISE6SEC, :offer_curves, AustralianElectricityMarkets.BidDirection.GEN)) ||
            isempty(filter(b -> b.service == BidType.RAISE6SEC, AustralianElectricityMarkets.get_fcas_bids(get_operation_cost(g))))
    end
end

@testset "units registered mid-chunk are built for the whole chunk" begin
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    grid = collect(interval)[1:(end - 1)]
    full = nem_system(aem_connect(HiveConfiguration(hive_location = hive)), NEMDEConfiguration(); date_range = interval)
    series(device, name) = get_time_series_values(SingleTimeSeries, device, name; ignore_scaling_factors = true) .* get_base_power(full)
    # Natural-unit telemetry and observed-state series, as published.
    raw(device, name) = get_time_series_values(SingleTimeSeries, device, name; ignore_scaling_factors = true)
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
    connect(source) = aem_connect(HiveConfiguration(hive_location = source, filesystem = "file"))
    late_hive = registered_from(hive, "BW02", "2025-01-01 00:10:00")
    late = nem_system(connect(late_hive), NEMDEConfiguration(); date_range = interval)
    bw02 = get_component(Generator, late, "BW02")
    bw02_full = get_component(Generator, full, "BW02")
    # BW02 is registered only at 00:15, so the two earlier stamps are zero-padded.
    @test series(bw02, "bid_energy_max_avail_gen") ≈ [0.0, 0.0, series(bw02_full, "bid_energy_max_avail_gen")[3]]
    @test raw(bw02, "observed_initial_mw") ≈ [0.0, 0.0, raw(bw02_full, "observed_initial_mw")[3]]
    # Ramp rates have no value at the stamps without a row; the AGC ramp reads them as NaN there.
    for name in ("telemetry_ramp_up_limit", "telemetry_ramp_down_limit")
        @test isnan.(raw(bw02, name)[1:2]) == [true, true]
        @test raw(bw02, name)[3] ≈ raw(bw02_full, name)[3]
    end
    @test length(get_time_series_timestamps(SingleTimeSeries, bw02, "bid_energy_max_avail_gen")) == length(grid)

    # Every single-time-series input of every injection spans the whole chunk.
    for device in get_components(StaticInjection, late), key in get_time_series_keys(device)
        get_time_series_type(key) === SingleTimeSeries || continue
        stamps = get_time_series_timestamps(SingleTimeSeries, device, get_name(key))
        @test stamps == grid
    end
    @test isempty(get_dropped_terms(late))
    @test isempty(get_skipped_constraints(late))

    @testset "BW02's padded offer curve has no width" begin
        raise6 = BidType.RAISE6SEC
        # The padded offer curve has zero width, so the service bid offers nothing there.
        svc = only(s for s in get_components(FCASService, late) if get_bid_type(s) == raise6 && "BW02" in get_name.(get_contributing_devices(late, s)))
        curves = get_time_series_values(SingleTimeSeries, bw02, AustralianElectricityMarkets.bid_series_name(BidType.RAISE6SEC, :offer_curves, AustralianElectricityMarkets.BidDirection.GEN); ignore_scaling_factors = true)
        @test all(i -> sum(diff(PowerSystems.get_x_coords(curves[i]))) == 0.0, 1:2)
    end
    @test_nowarn PowerSystems.transform_single_time_series!(late, DISPATCH_INTERVAL, DISPATCH_INTERVAL)

    @testset "a partly published FCAS trapezium is zero where AEMO publishes none" begin
        partial = damaged_cache(
            hive, :BIDPEROFFER_D,
            "DELETE FROM input WHERE DUID = 'BW01' AND BIDTYPE <> 'ENERGY' AND INTERVAL_DATETIME = TIMESTAMP '2025-01-01 00:05:00'",
        )
        sys = nem_system(partial, NEMDEConfiguration(); date_range = interval)
        battery = get_component(NEMStorage, sys, "BW01")
        battery_full = get_component(NEMStorage, full, "BW01")
        trapezium = AustralianElectricityMarkets.bid_series_name(BidType.RAISE6SEC, :trapezium, AustralianElectricityMarkets.BidDirection.GEN)
        values = get_time_series_values(SingleTimeSeries, battery, trapezium; ignore_scaling_factors = true)
        @test length(values) == length(grid)
        @test isequal(values[1], (0.0, 0.0, 0.0, 0.0))
        @test isequal(values[2:3], get_time_series_values(SingleTimeSeries, battery_full, trapezium; ignore_scaling_factors = true)[2:3])
        # Every FCAS offer curve, whichever device carries it, spans the whole chunk.
        bidders = Iterators.flatten((get_components(Generator, sys), get_components(Storage, sys), get_components(ControllableLoad, sys)))
        for device in bidders, bid in AustralianElectricityMarkets.get_fcas_bids(get_operation_cost(device))
            @test length(get_time_series_values(SingleTimeSeries, device, bid.offer_curves.name; ignore_scaling_factors = true)) == length(grid)
        end
    end

    @testset "a non-scheduled FCAS-only load is zero where its data stops" begin
        stopped = damaged_cache(
            hive, :DISPATCHLOAD,
            "DELETE FROM input WHERE DUID = 'ASLOAD1' AND SETTLEMENTDATE = TIMESTAMP '2025-01-01 00:15:00'",
        ).config.hive_location
        stopped = damaged_cache(
            stopped, :BIDPEROFFER_D,
            "DELETE FROM input WHERE DUID = 'ASLOAD1' AND INTERVAL_DATETIME = TIMESTAMP '2025-01-01 00:15:00'",
        ).config.hive_location
        sys = nem_system(connect(stopped), NEMDEConfiguration(); date_range = interval)
        load = get_component(NEMLoad, sys, "ASLOAD1")
        @test all(iszero, raw(load, "observed_initial_mw"))
        values = get_time_series_values(SingleTimeSeries, load, AustralianElectricityMarkets.bid_series_name(BidType.RAISE6SEC, :trapezium, AustralianElectricityMarkets.BidDirection.LOAD); ignore_scaling_factors = true)
        @test length(values) == length(grid)
        @test all(iszero, values[3])
    end

    @testset "a unit deregistered inside the chunk is zero after its last stamp" begin
        ended = damaged_cache(hive, :DUDETAILSUMMARY, "UPDATE input SET END_DATE = TIMESTAMP '2025-01-01 00:10:00' WHERE DUID = 'BW04'").config.hive_location
        ended = damaged_cache(ended, :BIDPEROFFER_D, "DELETE FROM input WHERE DUID = 'BW04' AND INTERVAL_DATETIME = TIMESTAMP '2025-01-01 00:15:00'").config.hive_location
        ended = damaged_cache(ended, :DISPATCHLOAD, "DELETE FROM input WHERE DUID = 'BW04' AND SETTLEMENTDATE = TIMESTAMP '2025-01-01 00:15:00'").config.hive_location
        sys = nem_system(connect(ended), NEMDEConfiguration(); date_range = interval)
        gen = get_component(NEMRenewableGen, sys, "BW04")
        @test raw(gen, "telemetry_uigf")[3] == 0.0
    end

    @testset "a semi-scheduled unit registered mid-chunk has zero UIGF before registration" begin
        semi_late = registered_from(hive, "BW03", "2025-01-01 00:10:00")
        sys = nem_system(connect(semi_late), NEMDEConfiguration(); date_range = interval)
        gen = get_component(NEMRenewableGen, sys, "BW03")
        @test get_registration(gen).schedule_type == ScheduleType.SEMI_SCHEDULED
        @test raw(gen, "telemetry_uigf")[1:2] == [0.0, 0.0]
        @test raw(gen, "telemetry_uigf")[3] ≈ raw(get_component(NEMRenewableGen, full, "BW03"), "telemetry_uigf")[3]
    end

    @testset "missing rows inside a registration still throw" begin
        gap = damaged_cache(hive, :DISPATCHLOAD, "DELETE FROM input WHERE DUID = 'BW01' AND SETTLEMENTDATE = TIMESTAMP '2025-01-01 00:10:00'")
        @test_throws r"BW01.*missing DISPATCHLOAD" nem_system(gap, NEMDEConfiguration(); date_range = interval)
        gap = damaged_cache(hive, :BIDPEROFFER_D, "DELETE FROM input WHERE DUID = 'BW03' AND BIDTYPE = 'ENERGY' AND DIRECTION = 'GEN' AND INTERVAL_DATETIME = TIMESTAMP '2025-01-01 00:10:00'")
        @test_throws r"incomplete energy bid inputs for BW03 GEN" nem_system(gap, NEMDEConfiguration(); date_range = interval)
        gap = damaged_cache(late_hive, :BIDPEROFFER_D, "DELETE FROM input WHERE DUID = 'BW02' AND BIDTYPE = 'ENERGY' AND DIRECTION = 'GEN' AND INTERVAL_DATETIME = TIMESTAMP '2025-01-01 00:15:00'")
        @test_throws r"incomplete energy bid inputs for BW02 GEN" nem_system(gap, NEMDEConfiguration(); date_range = interval)
    end

    @testset "the as-of network keeps units in force at the first stamp" begin
        # The regional build itself needs a region with generators left, so the unit table is checked directly.
        network, units, _ = AustralianElectricityMarkets.RegionModel._nem_network(connect(late_hive); as_of = DateTime(2025, 1, 1, 0, 5))
        @test !("BW02" in units.DUID)
        @test isnothing(get_component(Generator, network, "BW02"))
    end
end
