@testset "ConstrainedNetworkConfiguration" begin

    hive_dir = AEM_TEST_HIVE_DIR
    config = isempty(hive_dir) ? HiveConfiguration() : HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(config)

    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))

    cnc_required_tables = table_requirements(ConstrainedNetworkConfiguration())
    @test :DISPATCH_FCAS_REQ in cnc_required_tables
    @test :DISPATCH_FCAS_REQ_CONSTRAINT in cnc_required_tables
    @test :DISPATCHCONSTRAINT in cnc_required_tables
    @test :GENCONDATA in cnc_required_tables
    @test :DISPATCHLOAD in cnc_required_tables
    @test :BIDPEROFFER_D in cnc_required_tables
    @test :SPDCONNECTIONPOINTCONSTRAINT in cnc_required_tables
    @test :SPDREGIONCONSTRAINT in cnc_required_tables
    @test :SPDINTERCONNECTORCONSTRAINT in cnc_required_tables

    sys = nem_system(db, ConstrainedNetworkConfiguration(); date_range = date_range)
    @test !isempty(collect(get_components(GenericConstraint, sys)))
    found = false
    for gen in get_components(Generator, sys)
        # has_time_series (not get_time_series + isnothing): get_time_series throws
        # ArgumentError, rather than returning nothing, for an owner with no metadata
        # registered at all - confirmed directly, same as "set_fcas_bids!" above. Series
        # name is "fcas_curve_<SERVICE>" per set_fcas_bids!, not "fcas_bid_<SERVICE>".
        has_time_series(gen, Deterministic, "fcas_curve_RAISE6SEC") || continue
        found = true
    end
    @test found

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

    @testset "add_nem_constraints! keywords plumb through nem_system" begin
        sys_solution = nem_system(
            db, ConstrainedNetworkConfiguration(); date_range = date_range, include_solution = true,
        )
        gc_solution = first(get_components(GenericConstraint, sys_solution))
        @test has_time_series(gc_solution, Deterministic, "lhs")

        sys_res = nem_system(
            db, ConstrainedNetworkConfiguration(); date_range = date_range, resolution = Minute(30),
        )
        gc_res = first(get_components(GenericConstraint, sys_res))
        @test get_resolution(get_time_series(Deterministic, gc_res, "rhs")) == Minute(30)
    end

end
