# NEMDE units of a nem_system build: energy offers, MAXAVAIL, FCAS offers and the series the accessors read.
const RU_NEMDE_HIVE = mktempdir()
create_mock_data(RU_NEMDE_HIVE; complete_inputs = true)
write_mock_interconnector_results(RU_NEMDE_HIVE)

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

const RU_INTERVAL = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
const RU_SYS = nem_system(aem_connect(HiveConfiguration(hive_location = RU_NEMDE_HIVE, filesystem = "file")), NEMDEConfiguration(); date_range = RU_INTERVAL)

# The mock hive's network with bids, unit conditions and NEMDE inputs set over an hour, stage by stage.
const RU_DB = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
const RU_START = DateTime(2025, 1, 1, 0, 0)
const RU_RANGE = RU_START:Minute(5):(RU_START + Hour(1))
const RU_NETWORK = first(nem_network(RU_DB))
const RU_STAGED = let sys = deepcopy(RU_NETWORK)
    set_market_bids!(sys, RU_DB, RU_RANGE)
    set_unit_conditions!(sys, RU_DB, RU_RANGE)
    AustralianElectricityMarkets._set_nemde_inputs!(sys)
    sys
end

@testset "derived offers equal the values attached before the bids were split out" begin
    sys = RU_SYS
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
    late_hive = _ru_registered_from(RU_NEMDE_HIVE, "BW02", "2025-01-01 00:10:00")
    late = nem_system(
        aem_connect(HiveConfiguration(hive_location = late_hive, filesystem = "file")), NEMDEConfiguration(); date_range = RU_INTERVAL,
    )
    bw02 = get_component(Generator, late, "BW02")
    # BW02's RAISE6SEC is a modelled incremental bid, so its effective offer is disabled where AEMO publishes none.
    inactive = -FCAS_INACTIVE_LIMIT_MW / get_base_power(late)
    effective = get_time_series_values(SingleTimeSeries, bw02, fcas_effective_series_name(BidType.RAISE6SEC, false); ignore_scaling_factors = true)
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

@testset "energy offer views of each side, and none without an energy bid or NEM unit data" begin
    AEM = AustralianElectricityMarkets
    sys = deepcopy(RU_STAGED)
    gen = first(get_components(ThermalStandard, sys))
    for device in (gen, get_components(EnergyReservoirStorage, sys)...), side in AEM.energy_offer_sides(device)
        offer = AEM._energy_offer_view(device, side)
        ta = get_time_series_array(SingleTimeSeries, device, energy_offer_series_name(side))
        @test offer.side == side
        @test offer.timestamps == PowerSystems.TimeSeries.timestamp(ta) && offer.curves == values(ta)
        @test offer.timestamps[1] == RU_RANGE[1]
    end
    @test isnothing(AEM._energy_offer_view(gen, OfferSide.LOAD))
    @test isnothing(AEM._energy_offer_view(first(get_components(PowerLoad, sys)), OfferSide.GEN))
    stock = ThermalStandard(;
        name = "stock", available = true, status = true, bus = first(get_components(ACBus, sys)), active_power = 0.0, reactive_power = 0.0, rating = 1.0,
        active_power_limits = (min = 0.0, max = 1.0), reactive_power_limits = nothing, ramp_limits = nothing,
        operation_cost = ThermalGenerationCost(nothing), base_power = 100.0,
    )
    add_component!(sys, stock)
    @test isnothing(AEM._energy_offer_view(stock, OfferSide.GEN))
end

@testset "a second set_market_bids! replaces the bid series timestamps" begin
    sys = deepcopy(RU_NETWORK)
    second_range = (RU_START + Minute(30)):Minute(5):(RU_START + Minute(90))
    set_market_bids!(sys, RU_DB, RU_RANGE)
    set_unit_conditions!(sys, RU_DB, RU_RANGE)
    set_market_bids!(sys, RU_DB, second_range)
    for device in vcat(collect(get_components(ThermalStandard, sys)), collect(get_components(EnergyReservoirStorage, sys)))
        get_available(device) || continue
        for bid in AustralianElectricityMarkets.get_energy_bids(AustralianElectricityMarkets._nem_offer_cost(device))
            name = bid_series_name(BidType.ENERGY, :offer_curves, bid.direction)
            @test first(get_time_series_timestamps(SingleTimeSeries, device, name)) == second_range[1]
        end
    end
end

@testset "a one-interval range is refused" begin
    @test_throws ArgumentError set_unit_conditions!(deepcopy(RU_NETWORK), RU_DB, RU_START:Minute(5):(RU_START + Minute(5)))
end

@testset "FCAS offers point at the bid series" begin
    AEM = AustralianElectricityMarkets
    sys = deepcopy(RU_SYS)
    bw01 = get_component(EnergyReservoirStorage, sys, "BW01")
    bid = only(
        b for b in AEM.get_fcas_bids(AEM._nem_offer_cost(bw01))
            if b.service == BidType.RAISEREG && AEM._fcas_bid_side(bw01, b) == OfferSide.GEN
    )
    @test AEM._fcas_offer_key(bw01, BidType.RAISEREG, OfferSide.GEN) == bid.offer_curves
    # Removes BW01's RAISEREG service, so its bid is unmodelled and has no offer key.
    raisereg = only(s for s in PowerSystems.get_services(bw01) if s isa FCASService && AEM.get_bid_type(s) == BidType.RAISEREG)
    PowerSystems.remove_service!(bw01, raisereg)
    @test isnothing(AEM._fcas_offer_key(bw01, BidType.RAISEREG, OfferSide.GEN))
end
