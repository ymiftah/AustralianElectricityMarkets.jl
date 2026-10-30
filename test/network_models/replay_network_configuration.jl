@testset "Replay requirements include mandatory MNSP metering" begin
    @test :DISPATCHINTERCONNECTORRES in table_requirements(NEMDEConfiguration())
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
    gen = get_component(RenewableDispatch, sys, "BW03")
    @test get_ext(gen)["nem_semi_scheduled"] === true
    @test get_time_series_values(SingleTimeSeries, gen, "energy_max_avail"; ignore_scaling_factors = true) .* get_base_power(sys) ≈ [101.0, 102.0, 103.0]
    @test get_time_series_values(SingleTimeSeries, gen, "uigf"; ignore_scaling_factors = true) .* get_base_power(sys) ≈ [41.0, 42.0, 43.0]
    @test !has_time_series(gen, DeterministicSingleTimeSeries, "energy_max_avail")
    @test !isempty(collect(get_components(FCASService, sys)))
    ic = get_component(AreaInterchange, sys, "IC2")
    @test has_time_series(ic, SingleTimeSeries, "mnsp_forward_max_avail")
    @test !has_time_series(ic, SingleTimeSeries, "from_to_flow_limit")
    diagnostic = nem_system(db, config; date_range = interval, interval_flow_limits = true)
    @test has_time_series(get_component(AreaInterchange, diagnostic, "IC2"), SingleTimeSeries, "from_to_flow_limit")
    directory = mktempdir()
    on_disk = nem_system(db, config; date_range = interval, time_series_in_memory = false, time_series_directory = directory)
    @test !isempty(readdir(directory))
    @test get_time_series_values(SingleTimeSeries, get_component(RenewableDispatch, on_disk, "BW03"), "uigf"; ignore_scaling_factors = true) .* get_base_power(on_disk) ≈ [41.0, 42.0, 43.0]
    physical_db = damaged_cache(
        hive, :DISPATCHLOAD,
        "INSERT INTO input SELECT * REPLACE (1 AS INTERVENTION, INITIALMW + CASE WHEN DUID = 'BW03' THEN 10 ELSE 0 END AS INITIALMW) FROM input WHERE INTERVENTION = 0",
    )
    physical = nem_system(physical_db, config; date_range = interval, intervention = 1)
    physical_gen = get_component(RenewableDispatch, physical, "BW03")
    @test get_time_series_values(SingleTimeSeries, physical_gen, "initial_mw"; ignore_scaling_factors = true) .- get_time_series_values(SingleTimeSeries, gen, "initial_mw"; ignore_scaling_factors = true) ≈ fill(10 / get_base_power(sys), 3)
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

@testset "Replay shared inputs preserve independent setter results" begin
    AEM = AustralianElectricityMarkets
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    grid = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    shared, units = AEM.RegionModel._constrained_system(db; date_range = grid)
    independent, _ = AEM.RegionModel._constrained_system(db; date_range = grid)
    @test isequal(units, read_units(db; as_of = first(grid)))
    demand = read_demand(db, grid; resolution = Minute(5))
    demand_before = deepcopy(demand)
    dispatch = read_dispatch_limits(db, grid; intervention = 0, resolution = Minute(5))
    AEM._set_demand!(shared, demand, grid; resolution = Minute(5))
    attach_demand!(independent, db, grid; resolution = Minute(5))
    @test isequal(demand, demand_before)
    for sys in (shared, independent)
        set_market_bids!(sys, db, grid; resolution = Minute(5))
        set_fcas_scaling_inputs!(sys, db, grid)
    end
    AEM._set_nem_dispatch_limits!(shared, dispatch, grid)
    attach_dispatch_limits!(independent, db, grid)
    for T in (PowerLoad, ThermalStandard, HydroDispatch, RenewableDispatch, EnergyReservoirStorage, InterruptiblePowerLoad), component in get_components(T, shared)
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

@testset "NEMDE network builds generators with zero operation costs" begin
    AEM = AustralianElectricityMarkets
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    sys, _, _ = AEM.RegionModel._nem_network(db)
    generators = collect(get_components(Generator, sys))
    @test !isempty(generators)
    @test all(g -> get_operation_cost(g) isa Union{RenewableGenerationCost, HydroGenerationCost, ThermalGenerationCost}, generators)
    @test all(g -> AEM._is_zero_cost(get_operation_cost(g)), generators)
end

@testset "FCAS offers on a zero-cost device without an energy bid" begin
    AEM = AustralianElectricityMarkets
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    grid = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    sys, _ = AEM.RegionModel._constrained_system(db; date_range = grid)
    # FCAS price bids are stored only by NEMDEConfiguration, so no device carries an offer curve here.
    @test !any(
        has_time_series(device, SingleTimeSeries, fcas_offer_series_name(svc, dec))
            for device in get_components(Device, sys), svc in get_components(FCASService, sys), dec in (false, true)
    )
    # No set_market_bids!: each bidder keeps its zero cost and gets an empty MarketBidCost.
    bidders = [g for g in get_components(Generator, sys) if has_time_series(g, SingleTimeSeries, "fcas_trapezium_RAISE6SEC")]
    @test !isempty(bidders)
    set_fcas_service_bids!(sys, db, grid)
    for g in bidders
        cost = get_operation_cost(g)
        @test cost isa MarketBidCost
    end
end

@testset "NEMDE replay attaches FCAS effective offers and tie-break scales" begin
    AEM = AustralianElectricityMarkets
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    sys = nem_system(db, NEMDEConfiguration(); date_range = interval)
    series = [
        get_name(key) for device in get_components(StaticInjection, sys)
            for key in PowerSystems.get_time_series_keys(device)
    ]
    @test any(startswith(name, "fcas_effective_") for name in series)
    # The mock's energy bands are never tied across units within an interval, so no tie-break scale is written;
    # the EnergyTieBreak service below still records that set_tie_break_scales! ran.
    @test !any(startswith(name, "tie_break_scale_") for name in series)
    service = get_component(AEM.EnergyTieBreak, sys, AEM.TIE_BREAK_SERVICE_NAME)
    @test !isnothing(service)
    @test !isempty(get_contributing_devices(sys, service))
end

@testset "units registered mid-chunk are built for the whole chunk" begin
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    grid = collect(interval)[1:(end - 1)]
    full = nem_system(aem_connect(HiveConfiguration(hive_location = hive)), NEMDEConfiguration(); date_range = interval)
    series(device, name) = get_time_series_values(SingleTimeSeries, device, name; ignore_scaling_factors = true) .* get_base_power(full)
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
    for name in ("energy_max_avail", "availability", "initial_mw", "ramp_up_rate", "ramp_down_rate")
        @test series(bw02, name) ≈ [0.0, 0.0, series(bw02_full, name)[3]]
    end
    @test length(get_time_series_timestamps(SingleTimeSeries, bw02, "energy_max_avail")) == length(grid)

    # Every single-time-series input of every injection spans the whole chunk.
    for device in get_components(StaticInjection, late), key in get_time_series_keys(device)
        get_time_series_type(key) === SingleTimeSeries || continue
        stamps = get_time_series_timestamps(SingleTimeSeries, device, get_name(key))
        @test stamps == grid
    end
    @test isempty(get_dropped_terms(late))
    @test isempty(get_skipped_constraints(late))
    @test_nowarn prepare_replay_forecasts!(late)

    @testset "a partly published FCAS trapezium is zero where AEMO publishes none" begin
        partial = damaged_cache(
            hive, :BIDPEROFFER_D,
            "DELETE FROM input WHERE DUID = 'BW01' AND BIDTYPE <> 'ENERGY' AND INTERVAL_DATETIME = TIMESTAMP '2025-01-01 00:05:00'",
        )
        sys = nem_system(partial, NEMDEConfiguration(); date_range = interval)
        battery = get_component(EnergyReservoirStorage, sys, "BW01")
        battery_full = get_component(EnergyReservoirStorage, full, "BW01")
        trapezium = fcas_series_name("fcas_trapezium", BidType.RAISE6SEC, false)
        values = get_time_series_values(SingleTimeSeries, battery, trapezium; ignore_scaling_factors = true)
        @test length(values) == length(grid)
        @test isequal(values[1], (0.0, 0.0, 0.0, 0.0, 0.0, NaN, NaN))
        @test isequal(values[2:3], get_time_series_values(SingleTimeSeries, battery_full, trapezium; ignore_scaling_factors = true)[2:3])
        # Every FCAS offer curve, whichever device carries it, spans the whole chunk.
        for svc in get_components(FCASService, sys), device in get_contributing_devices(sys, svc), decremental in (false, true)
            has_time_series(device, SingleTimeSeries, fcas_offer_series_name(svc, decremental)) || continue
            @test length(get_time_series_values(SingleTimeSeries, device, fcas_offer_series_name(svc, decremental); ignore_scaling_factors = true)) == length(grid)
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
        load = get_component(InterruptiblePowerLoad, sys, "ASLOAD1")
        @test all(iszero, series(load, "initial_mw"))
        values = get_time_series_values(SingleTimeSeries, load, fcas_series_name("fcas_trapezium", BidType.RAISE6SEC, true); ignore_scaling_factors = true)
        @test length(values) == length(grid)
        @test all(iszero, values[3][1:5])
    end

    @testset "a unit deregistered inside the chunk is zero after its last stamp" begin
        ended = damaged_cache(hive, :DUDETAILSUMMARY, "UPDATE input SET END_DATE = TIMESTAMP '2025-01-01 00:10:00' WHERE DUID = 'BW04'").config.hive_location
        ended = damaged_cache(ended, :BIDPEROFFER_D, "DELETE FROM input WHERE DUID = 'BW04' AND INTERVAL_DATETIME = TIMESTAMP '2025-01-01 00:15:00'").config.hive_location
        ended = damaged_cache(ended, :DISPATCHLOAD, "DELETE FROM input WHERE DUID = 'BW04' AND SETTLEMENTDATE = TIMESTAMP '2025-01-01 00:15:00'").config.hive_location
        sys = nem_system(connect(ended), NEMDEConfiguration(); date_range = interval)
        gen = get_component(RenewableDispatch, sys, "BW04")
        @test series(gen, "availability")[1:2] ≈ series(get_component(RenewableDispatch, full, "BW04"), "availability")[1:2]
        @test series(gen, "availability")[3] == 0.0
        @test series(gen, "uigf")[3] == 0.0
    end

    @testset "a semi-scheduled unit registered mid-chunk has zero UIGF before registration" begin
        semi_late = registered_from(hive, "BW03", "2025-01-01 00:10:00")
        sys = nem_system(connect(semi_late), NEMDEConfiguration(); date_range = interval)
        gen = get_component(RenewableDispatch, sys, "BW03")
        @test get_ext(gen)["nem_semi_scheduled"] === true
        @test series(gen, "uigf")[1:2] == [0.0, 0.0]
        @test series(gen, "uigf")[3] ≈ series(get_component(RenewableDispatch, full, "BW03"), "uigf")[3]
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
