@testset "referred_price divides the price by the loss factor and rounds to cents" begin
    @test AustralianElectricityMarkets.referred_price(100.0, 0.97) == 103.09
    @test AustralianElectricityMarkets.referred_price(-1000.0, 1.0312) == -969.74
end

# Checks each energy offer series of `sys` against the bid's raw curves, referred by the registration's
# loss factor of its side. Returns the number of series checked.
function _check_referred_energy_offers(sys)
    AEM = AustralianElectricityMarkets
    checked = 0
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
            checked += 1
        end
    end
    return checked
end

@testset "NEMDE replay writes the referred energy offer curves without AEMSim" begin
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    t = DateTime(2025, 1, 1, 0, 5)
    sys = nem_system(db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(20)))
    @test _check_referred_energy_offers(sys) > 0
end

@testset "energy offers are referred by the loss factor of their own side" begin
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    t = DateTime(2025, 1, 1, 0, 5)
    sys = nem_system(db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(20)))
    AEM = AustralianElectricityMarkets
    # Distinct factors per side, so a swap of the two would change the expected prices.
    for device in AEM._bidding_devices(sys)
        isnothing(AEM._nem_offer_cost(device)) && continue
        for name in ("energy_offer", "energy_offer_decremental")
            AEM.remove_single_series!(sys, device, name)
        end
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
    @test _check_referred_energy_offers(sys) > 0
end
