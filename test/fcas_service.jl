@testset "PSCB FCASService" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates

    config = HiveConfiguration(hive_location = AEM_TEST_PSCB_HIVE_DIR, filesystem = "file")
    db = aem_connect(config)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(2) + Minute(5))

    # Independently computed region ∩ bid-coverage set, mirroring _fcas_service_devices
    # without calling it, so the test doesn't just re-assert the implementation.
    function _expected_service_devices(sys, region::AbstractString, bid_type::BidType)
        inc = "fcas_curve_$(string(bid_type))"
        dec = "fcas_curve_$(string(bid_type))_decremental"
        names = String[]
        for d in Iterators.flatten((get_components(Generator, sys), get_components(Storage, sys)))
            get_name(get_area(get_bus(d))) == region || continue
            (has_time_series(d, Deterministic, inc) || has_time_series(d, Deterministic, dec)) && push!(names, get_name(d))
        end
        return Set(names)
    end

    @testset "add_fcas_services! builds one service per governed (region, bid_type)" begin
        sys = augmented_pscb_system()
        set_fcas_bids!(sys, db, date_range)
        add_nem_constraints!(sys, db, date_range)
        added, skipped = add_fcas_services!(sys)

        @test Set(added) == Set(["1_RAISE6SEC", "2_LOWERREG"])
        @test isempty(skipped)

        svc1 = get_component(FCASService, sys, "1_RAISE6SEC")
        @test !isnothing(svc1)
        @test get_region(svc1) == "1"
        @test get_bid_type(svc1) == BidType.RAISE6SEC

        svc2 = get_component(FCASService, sys, "2_LOWERREG")
        @test !isnothing(svc2)
        @test get_region(svc2) == "2"
        @test get_bid_type(svc2) == BidType.LOWERREG

        @testset "contributing devices are exactly region ∩ bid coverage" begin
            actual1 = Set(
                get_name(d) for d in Iterators.flatten((get_components(Generator, sys), get_components(Storage, sys)))
                    if has_service(d, svc1)
            )
            @test actual1 == _expected_service_devices(sys, "1", BidType.RAISE6SEC)
            @test actual1 == Set(
                ["Alta", "Brighton", "Park City", "Sundance", "HydroDispatch1", "HydroDispatch2", "HydroDispatch3", "BAT1"],
            )

            actual2 = Set(
                get_name(d) for d in Iterators.flatten((get_components(Generator, sys), get_components(Storage, sys)))
                    if has_service(d, svc2)
            )
            @test actual2 == _expected_service_devices(sys, "2", BidType.LOWERREG)
            @test actual2 == Set(["Solitude", "SOLAR1"])
        end
    end

    @testset "empty-device (region, bid_type) pair is skipped, never added or thrown" begin
        sys = augmented_pscb_system()
        set_fcas_bids!(sys, db, date_range)
        add_nem_constraints!(sys, db, date_range)
        # BidType.ENERGY is outside FCAS_BID_TYPES, so set_fcas_bids! never attaches an
        # "fcas_curve_ENERGY" series - region "1" resolves to zero contributing devices.
        add_service!(
            sys,
            GenericConstraint(;
                name = "TEST_EMPTY_FCAS", sense = ConstraintSense.LE, rhs = 0.0,
                fcas_requirements = [FCASRequirement("1", BidType.ENERGY)],
            ),
            Device[],
        )

        added, skipped = add_fcas_services!(sys)
        @test skipped == Dict("1_ENERGY" => :no_devices)
        @test "1_ENERGY" ∉ added
        @test isnothing(get_component(FCASService, sys, "1_ENERGY"))
    end

    @testset "disarmed GenericConstraint's FCAS requirement is excluded" begin
        vname(gencon_id, version = 1) = "$gencon_id@2025-01-01#$version"
        sys = augmented_pscb_system()
        set_fcas_bids!(sys, db, date_range)
        add_nem_constraints!(sys, db, date_range)

        gc = get_component(GenericConstraint, sys, vname("F_R1_RAISE6SEC"))
        set_available!(gc, false)

        added, skipped = add_fcas_services!(sys)
        @test "1_RAISE6SEC" ∉ added
        @test isnothing(get_component(FCASService, sys, "1_RAISE6SEC"))
    end

    @testset "device with only a decremental bid series still contributes" begin
        # Neither this fixture nor mock_data.jl ever produces a decremental-only device -
        # every DUID that gets a LOAD row (BAT1 here, BW01 in mock_data.jl) also gets a
        # matching GEN row for the same bid type. Constructed directly instead: BAT1 gets
        # only a manual "fcas_curve_RAISE6SEC_decremental" series, no incremental one, and no
        # other region-"1" device gets any RAISE6SEC series at all.
        sys = augmented_pscb_system()
        bat = get_component(EnergyReservoirStorage, sys, "BAT1")
        add_time_series!(
            sys, bat,
            Deterministic(;
                name = "fcas_curve_RAISE6SEC_decremental",
                # Deterministic requires at least 2 points per forecast window.
                data = Dict(start_date => fill(PiecewiseStepData([0.0, 5.0], [10.0]), 2)),
                resolution = Minute(5), interval = Minute(5),
            ),
        )
        add_service!(
            sys,
            GenericConstraint(;
                name = "TEST_DECREMENTAL_ONLY", sense = ConstraintSense.LE, rhs = 0.0,
                fcas_requirements = [FCASRequirement("1", BidType.RAISE6SEC)],
            ),
            Device[],
        )

        added, skipped = add_fcas_services!(sys)
        @test "1_RAISE6SEC" in added
        svc = get_component(FCASService, sys, "1_RAISE6SEC")
        @test has_service(bat, svc)
    end

    @testset "get_region/get_bid_type accessors" begin
        svc = FCASService(; name = "1_RAISE6SEC", region = "1", bid_type = BidType.RAISE6SEC)
        @test get_region(svc) == "1"
        @test get_bid_type(svc) == BidType.RAISE6SEC
    end
end
