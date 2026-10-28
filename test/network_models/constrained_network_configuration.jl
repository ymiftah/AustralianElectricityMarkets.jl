@testset "Constrained layer: FCAS services, constraints and losses" begin

    hive_dir = AEM_TEST_HIVE_DIR
    config = HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(config)

    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))

    sys, _ = AustralianElectricityMarkets.RegionModel._constrained_system(db; date_range = date_range)
    @test !isempty(collect(get_components(GenericConstraint, sys)))
    # FCAS price bids are stored only by NEMDEConfiguration, so no device carries an offer curve here.
    @test !any(
        has_time_series(device, SingleTimeSeries, fcas_offer_series_name(svc, dec))
            for device in get_components(Device, sys), svc in get_components(FCASService, sys), dec in (false, true)
    )

    # add_fcas_services! is wired in as the constrained layer's third build step - confirm it
    # actually ran, not just that it's callable.
    @test !isempty(collect(get_components(FCASService, sys)))

    # attach_interconnector_losses! is wired in as the fourth build step - confirm at
    # least one AreaInterchange actually got its InterconnectorLossModel.
    has_loss_model = any(
        !isempty(get_supplemental_attributes(InterconnectorLossModel, ic))
            for ic in get_components(AreaInterchange, sys)
    )
    @test has_loss_model

end
