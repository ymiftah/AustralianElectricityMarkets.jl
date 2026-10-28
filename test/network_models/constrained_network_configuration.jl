@testset "ConstrainedNetworkConfiguration" begin

    hive_dir = AEM_TEST_HIVE_DIR
    config = HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(config)

    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))

    sys = nem_system(db, ConstrainedNetworkConfiguration(); date_range = date_range)
    @test !isempty(collect(get_components(GenericConstraint, sys)))
    # Generators here carry a fuel or O&M cost, so they keep it and get no FCAS offer curve. The
    # zero-cost non-scheduled load ASLOAD1 is the device that carries the RAISE6SEC decremental curve.
    raise6_services = filter(s -> get_bid_type(s) == BidType.RAISE6SEC, collect(get_components(FCASService, sys)))
    @test !any(gen -> any(svc -> has_time_series(gen, SingleTimeSeries, fcas_offer_series_name(svc, false)), raise6_services), get_components(Generator, sys))
    @test any(svc -> any(load -> has_time_series(load, SingleTimeSeries, fcas_offer_series_name(svc, true)), get_contributing_devices(sys, svc)), raise6_services)

    # add_fcas_services! is wired in as ConstrainedNetworkConfiguration's third build
    # step - confirm it actually ran, not just that it's callable.
    @test !isempty(collect(get_components(FCASService, sys)))

    # attach_interconnector_losses! is wired in as the fourth build step - confirm at
    # least one AreaInterchange actually got its InterconnectorLossModel.
    has_loss_model = any(
        !isempty(get_supplemental_attributes(InterconnectorLossModel, ic))
            for ic in get_components(AreaInterchange, sys)
    )
    @test has_loss_model

end
