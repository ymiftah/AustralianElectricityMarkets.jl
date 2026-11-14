# Replay units of a nem_system build: energy offers, MAXAVAIL, FCAS offers and the series the
# accessors read, moved from the Simulations offer tests (they exercise only AustralianElectricityMarkets).
const RU_REPLAY_HIVE = mktempdir()
create_mock_data(RU_REPLAY_HIVE; complete_inputs = true)
write_mock_interconnector_results(RU_REPLAY_HIVE)

# Reads `source` with the unit `duid` first registered at `stamp`, as NEMWEB has it.
function _ru_registered_from(source, duid, stamp)
    t = "TIMESTAMP '$stamp'"
    steps = [
        (:DUDETAILSUMMARY, "UPDATE input SET START_DATE = $t WHERE DUID = '$duid'"),
        (:DUDETAIL, "UPDATE input SET EFFECTIVEDATE = $t WHERE DUID = '$duid'"),
        (:BIDPEROFFER_D, "DELETE FROM input WHERE DUID = '$duid' AND INTERVAL_DATETIME <= $t"),
        (:DISPATCHLOAD, "DELETE FROM input WHERE DUID = '$duid' AND SETTLEMENTDATE < $t"),
    ]
    for (table, query) in steps
        source = damaged_cache(source, table, query).config.hive_location
    end
    return source
end

@testset "the replay input series survive a JSON round-trip" begin
    replay_db = aem_connect(HiveConfiguration(hive_location = RU_REPLAY_HIVE, filesystem = "file"))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    sys = nem_system(replay_db, NEMDEConfiguration(); date_range = interval)
    series_names(device) = sort([get_name(k) for k in get_time_series_keys(device) if get_time_series_type(k) === SingleTimeSeries])
    read(device) = [get_time_series_values(SingleTimeSeries, device, n; ignore_scaling_factors = true) for n in series_names(device)]
    json_path = joinpath(mktempdir(), "sys.json")
    to_json(sys, json_path)
    sys2 = System(json_path)
    checked = 0
    for device in get_components(StaticInjection, sys)
        back = get_component(typeof(device), sys2, get_name(device))
        @test series_names(back) == series_names(device)
        @test read(back) == read(device)
        checked += 1
    end
    @test checked > 0
    service = get_component(EnergyTieBreak, sys2, TIE_BREAK_SERVICE_NAME)
    @test sort!(get_name.(get_contributing_devices(sys2, service))) ==
        sort!(get_name.(get_contributing_devices(sys, get_component(EnergyTieBreak, sys, TIE_BREAK_SERVICE_NAME))))
end

@testset "derived offers equal the values attached before the bids were split out" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))
    resolution = Minute(5)
    sys_base, _ = nem_network(db)
    replay_db = aem_connect(HiveConfiguration(hive_location = RU_REPLAY_HIVE, filesystem = "file"))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    sys = nem_system(replay_db, NEMDEConfiguration(); date_range = interval)
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

@testset "a unit registered mid-chunk offers no FCAS where its padded stamps are" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))
    resolution = Minute(5)
    sys_base, _ = nem_network(db)
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    late_hive = _ru_registered_from(RU_REPLAY_HIVE, "BW02", "2025-01-01 00:10:00")
    late = nem_system(
        aem_connect(HiveConfiguration(hive_location = late_hive, filesystem = "file")), NEMDEConfiguration(); date_range = interval,
    )
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

@testset "energy offer views and MAXAVAIL per direction" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))
    resolution = Minute(5)
    sys_base, _ = nem_network(db)
    sys = deepcopy(sys_base)
    set_market_bids!(sys, db, date_range)
    set_unit_conditions!(sys, db, date_range)
    AustralianElectricityMarkets._set_replay_inputs!(sys)
    for bat in get_components(EnergyReservoirStorage, sys)
        gen_offer, load_offer = AustralianElectricityMarkets._energy_offer_view(bat, OfferSide.GEN), AustralianElectricityMarkets._energy_offer_view(bat, OfferSide.LOAD)
        ta_gen = get_time_series_array(SingleTimeSeries, bat, "energy_offer")
        ta_load = get_time_series_array(SingleTimeSeries, bat, "energy_offer_decremental")
        @test gen_offer.side == OfferSide.GEN && load_offer.side == OfferSide.LOAD
        @test gen_offer.timestamps == PowerSystems.TimeSeries.timestamp(ta_gen) && gen_offer.curves == values(ta_gen)
        @test load_offer.curves == values(ta_load)
    end
    @test isnothing(AustralianElectricityMarkets._energy_offer_view(first(get_components(PowerLoad, sys)), OfferSide.GEN))
end

@testset "a device without NEM unit data has no offer view" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))
    resolution = Minute(5)
    sys_base, _ = nem_network(db)
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
    @test isnothing(AustralianElectricityMarkets._energy_offer_view(stock, OfferSide.GEN))
    @test isnothing(AustralianElectricityMarkets._energy_offer_view(stock, OfferSide.LOAD))
end

@testset "offer views of each side after set_market_bids!" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))
    resolution = Minute(5)
    sys_base, _ = nem_network(db)
    sys = deepcopy(sys_base)
    set_market_bids!(sys, db, date_range)
    set_unit_conditions!(sys, db, date_range)
    AustralianElectricityMarkets._set_replay_inputs!(sys)
    gen = first(get_components(ThermalStandard, sys))
    storage = first(get_components(EnergyReservoirStorage, sys))
    for (device, side) in ((gen, OfferSide.GEN), (storage, OfferSide.GEN), (storage, OfferSide.LOAD))
        offer = AustralianElectricityMarkets._energy_offer_view(device, side)
        @test offer.side == side
        @test offer.curves == get_time_series_values(SingleTimeSeries, device, energy_offer_series_name(side))
        @test offer.timestamps[1] == date_range[1]
    end
end

@testset "a second set_market_bids! replaces the bid series timestamps" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))
    resolution = Minute(5)
    sys_base, _ = nem_network(db)
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

@testset "a one-interval range is refused, as a single-value series is at HEAD" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))
    resolution = Minute(5)
    sys_base, _ = nem_network(db)
    one = start_date:resolution:(start_date + resolution)
    @test_throws ArgumentError set_unit_conditions!(deepcopy(sys_base), db, one)
end

@testset "the written derived series and their names, and no energy_max_avail series" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))
    resolution = Minute(5)
    sys_base, _ = nem_network(db)
    sys = deepcopy(sys_base)
    set_market_bids!(sys, db, date_range; resolution = resolution)
    set_unit_conditions!(sys, db, date_range)
    AustralianElectricityMarkets._set_replay_inputs!(sys)
    names(device) = [get_name(k) for k in get_time_series_keys(device)]
    for device in get_components(StaticInjection, sys)
        @test !any(startswith("energy_max_avail"), names(device))
        @test !any(startswith("fcas_trapezium"), names(device))
    end

    device = get_component(ThermalStandard, sys, "ER01")
    @test has_time_series(device, SingleTimeSeries, "energy_offer")
    @test has_time_series(device, SingleTimeSeries, NEM_SERIES.ramp_up_rate)
    @test has_time_series(device, SingleTimeSeries, NEM_SERIES.ramp_down_rate)
    @test has_time_series(device, SingleTimeSeries, bid_series_name(BidType.RAISEREG, :trapezium, AustralianElectricityMarkets.BidDirection.GEN))

    battery = get_component(EnergyReservoirStorage, sys, "BW01")
end

@testset "FCAS offers point at the bid series" begin
    AEM = AustralianElectricityMarkets
    replay_db = aem_connect(HiveConfiguration(hive_location = RU_REPLAY_HIVE, filesystem = "file"))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    sys = nem_system(replay_db, NEMDEConfiguration(); date_range = interval)
    bw01 = get_component(EnergyReservoirStorage, sys, "BW01")
    bid = only(
        b for b in AEM.get_fcas_bids(AEM._nem_offer_cost(bw01))
            if b.service == BidType.RAISEREG && AEM._fcas_bid_side(bw01, b) == OfferSide.GEN
    )
    @test AEM._fcas_offer_key(bw01, BidType.RAISEREG, OfferSide.GEN) == bid.offer_curves
    @test !has_time_series(bw01, SingleTimeSeries, fcas_series_name("fcas_offer", BidType.RAISEREG, false))
    # Removes BW01's RAISEREG service, so its bid is unmodelled and has no offer key.
    raisereg = only(s for s in PowerSystems.get_services(bw01) if s isa FCASService && AEM.get_bid_type(s) == BidType.RAISEREG)
    PowerSystems.remove_service!(bw01, raisereg)
    @test isnothing(AEM._fcas_offer_key(bw01, BidType.RAISEREG, OfferSide.GEN))
end
