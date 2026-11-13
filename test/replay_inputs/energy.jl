@testset "referred_price divides the price by the loss factor and rounds to cents" begin
    @test AustralianElectricityMarkets.referred_price(100.0, 0.97) == 103.09
    @test AustralianElectricityMarkets.referred_price(-1000.0, 1.0312) == -969.74
end

# A NEM replay System on the mock hive, with its replay inputs written by `nem_system`.
function _energy_mock_system()
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    t = DateTime(2025, 1, 1, 0, 5)
    return nem_system(db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(20)))
end

# Removes the energy offer series of every bidding device of `sys`, so the writer can run again.
function _strip_energy_offers!(sys)
    AEM = AustralianElectricityMarkets
    for device in AEM._bidding_devices(sys), name in ("energy_offer", "energy_offer_decremental")
        remove_series_and_forecast!(sys, device, name)
    end
    return
end

# Checks each energy offer series of `sys` against the bid's raw curves, referred by the registration's
# loss factor of its side. Returns the numbers of GEN-side and LOAD-side series checked.
function _check_referred_energy_offers(sys)
    AEM = AustralianElectricityMarkets
    checked = Dict(AEM.OfferSide.GEN => 0, AEM.OfferSide.LOAD => 0)
    for device in AEM._bidding_devices(sys)
        cost = AEM._nem_offer_cost(device)
        isnothing(cost) && continue
        for side in AEM.energy_offer_sides(device)
            bid = AEM._energy_bid(cost, side)
            isnothing(bid) && continue
            direction = side == AEM.OfferSide.LOAD ? AEM.BidDirection.LOAD : AEM.BidDirection.GEN
            raw = PowerSystems.get_time_series_values(
                PowerSystems.SingleTimeSeries, device, AEM.bid_series_name(AEM.BidType.ENERGY, :offer_curves, direction);
                ignore_scaling_factors = true,
            )
            registration = AEM.get_registration(device)
            factor = side == AEM.OfferSide.LOAD ? registration.load_loss_factor : registration.gen_loss_factor
            written = PowerSystems.get_time_series_values(
                PowerSystems.SingleTimeSeries, device, AEM.energy_offer_series_name(side); ignore_scaling_factors = true,
            )
            @test [PowerSystems.get_x_coords(c) for c in written] == [PowerSystems.get_x_coords(c) for c in raw]
            @test [PowerSystems.get_y_coords(c) for c in written] == [round.(PowerSystems.get_y_coords(c) ./ factor; digits = 2) for c in raw]
            checked[side] += 1
        end
    end
    return checked
end

@testset "NEMDE replay writes the referred energy offer curves without AEMSim" begin
    sys = _energy_mock_system()
    checked = _check_referred_energy_offers(sys)
    @test checked[AustralianElectricityMarkets.OfferSide.GEN] > 0
    @test checked[AustralianElectricityMarkets.OfferSide.LOAD] > 0
end

@testset "energy offers are referred by the loss factor of their own side" begin
    AEM = AustralianElectricityMarkets
    sys = _energy_mock_system()
    # Distinct factors per side, so a swap of the two would change the expected prices.
    _strip_energy_offers!(sys)
    for device in AEM._bidding_devices(sys)
        isnothing(AEM._nem_offer_cost(device)) && continue
        registration = AEM.get_registration(device)
        AEM.set_registration!(
            device,
            AEM.NEMRegistration(;
                schedule_type = registration.schedule_type, gen_loss_factor = 0.9, load_loss_factor = 0.8,
                registered_from = registration.registered_from, registered_until = registration.registered_until,
                commissioned = registration.commissioned,
            ),
        )
    end
    AEM._set_referred_energy_offers!(sys)
    checked = _check_referred_energy_offers(sys)
    @test checked[AEM.OfferSide.GEN] > 0
    @test checked[AEM.OfferSide.LOAD] > 0
end

@testset "a static energy bid is rejected when the replay inputs are written" begin
    AEM = AustralianElectricityMarkets
    sys = _energy_mock_system()
    _strip_energy_offers!(sys)
    gen = PowerSystems.get_component(PowerSystems.ThermalStandard, sys, "ER01")
    AEM._nem_unit_data(gen).offer = AEM.NEMOfferCost(;
        energy = [
            AEM.NEMEnergyBid(;
                direction = AEM.BidDirection.GEN,
                offer_curves = PowerSystems.PiecewiseStepData([0.0, 10.0], [5.0]), max_avail = 10.0, roc_up = 0.0, roc_down = 0.0,
            ),
        ],
    )
    @test_throws r"static `offer_curves` field" AEM._set_replay_inputs!(sys)
end

@testset "two FCAS bids of one service on one side are rejected when the replay inputs are written" begin
    AEM = AustralianElectricityMarkets
    sys = _energy_mock_system()
    _strip_energy_offers!(sys)
    gen = PowerSystems.get_component(PowerSystems.ThermalStandard, sys, "ER01")
    max_avail_name = AEM.bid_series_name(AEM.BidType.ENERGY, :max_avail, AEM.BidDirection.GEN)
    stamps = PowerSystems.get_time_series_timestamps(PowerSystems.SingleTimeSeries, gen, max_avail_name)
    for direction in (AEM.BidDirection.GEN, AEM.BidDirection.BIDIRECTIONAL)
        name(f) = AEM.bid_series_name(AEM.BidType.RAISE6SEC, f, direction)
        remove_series_and_forecast!(sys, gen, name(:offer_curves))
        PowerSystems.add_time_series!(sys, gen, AEM.single_series(name(:offer_curves), first(stamps), fill(PowerSystems.PiecewiseStepData([0.0, 10.0], [5.0]), length(stamps)), Minute(5)))
        remove_series_and_forecast!(sys, gen, name(:max_avail))
        PowerSystems.add_time_series!(sys, gen, AEM.single_series(name(:max_avail), first(stamps), fill(10.0, length(stamps)), Minute(5)))
        remove_series_and_forecast!(sys, gen, name(:trapezium))
        PowerSystems.add_time_series!(sys, gen, AEM.single_series(name(:trapezium), first(stamps), fill((0.0, 10.0, 90.0, 100.0), length(stamps)), Minute(5)))
        AEM._set_fcas_bid!(
            AEM._nem_offer_cost(gen),
            AEM.NEMFCASBid(;
                service = AEM.BidType.RAISE6SEC, direction,
                offer_curves = AEM._series_key(gen, name(:offer_curves)),
                max_avail = AEM._series_key(gen, name(:max_avail)),
                trapezium = AEM._series_key(gen, name(:trapezium)),
            ),
        )
    end
    @test_throws r"has two .*RAISE6SEC.* bids on the .*GEN.* side" AEM._set_replay_inputs!(sys)
end
