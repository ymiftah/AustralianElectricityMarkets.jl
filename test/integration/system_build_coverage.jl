@testset "System build coverage and JSON round-trip" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates
    using DataFrames

    # This test builds one System through the PSCB fixture's manual builder-call sequence
    # (nem_system(db, ConstrainedNetworkConfiguration(); ...) can't be used here - see
    # pscb_nemweb_data.jl's top-of-file comment), asserts every constraint/FCAS/loss input the
    # System should carry, then re-asserts the same coverage after a JSON round-trip.
    config = HiveConfiguration(hive_location = AEM_TEST_PSCB_HIVE_DIR, filesystem = "file")
    db = aem_connect(config)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(2) + Minute(5))
    vname(gencon_id, version = 1) = "$gencon_id@2025-01-01#$version"

    function build_system()
        sys = augmented_pscb_system()
        set_fcas_bids!(sys, db, date_range)
        add_nem_constraints!(sys, db, date_range)
        add_fcas_services!(sys)
        attach_interconnector_losses!(sys, db, first(date_range))
        return sys
    end

    # Run against both the freshly-built System and its JSON round-trip.
    function assert_coverage_matrix(sys)
        @testset "invoked generic constraints" begin
            gc_v1 = get_component(GenericConstraint, sys, vname("N_VERSIONED_LIMIT", 1))
            gc_v2 = get_component(GenericConstraint, sys, vname("N_VERSIONED_LIMIT", 2))
            @test !isnothing(gc_v1)
            @test !isnothing(gc_v2)
            for gc in (gc_v1, gc_v2)
                rhs_series = first(values(get_data(get_time_series(Deterministic, gc, "rhs"))))
                invoked_series = first(values(get_data(get_time_series(Deterministic, gc, "invoked"))))
                @test length(rhs_series) == length(date_range) - 1
                @test length(invoked_series) == length(date_range) - 1
            end
        end

        @testset "constraint LHS: RegionTerm devices" begin
            gc = get_component(GenericConstraint, sys, vname("F_R1_RAISE6SEC"))
            region_term = only(filter(t -> t isa RegionTerm, get_terms(gc)))
            @test !isempty(get_devices(region_term))
        end

        @testset "FCAS bids and trapezia" begin
            alta = get_component(ThermalStandard, sys, "Alta")
            trapezium = only(get_fcas_trapezium(alta, BidType.RAISE6SEC, start_date, 1))
            curve = only(get_fcas_offer_curve(alta, BidType.RAISE6SEC, start_date, 1))
            bid = only(get_fcas_bid(alta, BidType.RAISE6SEC, start_date, 1))
            @test trapezium isa FCASTrapezium
            @test curve isa PiecewiseStepData
            @test bid isa FCASBid
        end

        @testset "FCAS market anchors" begin
            svc1 = get_component(FCASService, sys, "1_RAISE6SEC")
            svc2 = get_component(FCASService, sys, "2_LOWERREG")
            @test !isnothing(svc1)
            @test !isnothing(svc2)
            devices(svc) = [
                d for d in Iterators.flatten((get_components(Generator, sys), get_components(Storage, sys)))
                    if has_service(d, svc)
            ]
            @test !isempty(devices(svc1))
            @test !isempty(devices(svc2))
        end

        @testset "interconnector losses" begin
            ic1 = get_component(AreaInterchange, sys, "IC1")
            model = only(get_supplemental_attributes(InterconnectorLossModel, ic1))
            @test model.interconnector == "IC1"
            # A prior PR in this stack lost this field's concrete type across a JSON
            # round-trip - check it specifically on the reloaded value, not just the field's
            # presence.
            @test model.demand_coefficients isa Dict{String, Float64}
        end
        return nothing
    end

    sys = build_system()
    assert_coverage_matrix(sys)

    @testset "DISPATCHLOAD: INITIALMW and UIGF are queryable" begin
        dispatch = read_fcas_dispatch(db, date_range)
        @test !isempty(dispatch)
        @test all(!ismissing, dispatch.INITIALMW)

        uigf = read_uigf(db, date_range)
        @test !isempty(uigf)
        # UIGF is populated only for SOLAR1 (the fixture's only semi-scheduled unit) -
        # read_uigf drops missing rows, so only SOLAR1 should come back.
        @test Set(uigf.DUID) == Set(["SOLAR1"])
    end

    @testset "unit contract: per-unit under SYSTEM_BASE, native MW/\$ under NATURAL_UNITS" begin
        gc = get_component(GenericConstraint, sys, vname("F_R1_RAISE6SEC"))
        sundance = get_component(ThermalStandard, sys, "Sundance")
        base_power = get_base_power(sys)

        # augmented_pscb_system() leaves sys in NATURAL_UNITS - same MW/$ ranges the
        # pre-PR-1.12 contract asserted directly off the stored fields.
        @test get_units_base(sys) == "NATURAL_UNITS"
        rhs_mw = get_rhs(gc)
        limits_mw = get_active_power_limits(sundance)
        trapezium_mw = only(get_fcas_trapezium(sundance, BidType.RAISE6SEC, start_date, 1))
        @test 10.0 <= rhs_mw <= 200.0
        @test 10.0 <= limits_mw.max <= 500.0
        @test 10.0 <= get_max_avail(trapezium_mw) <= 500.0

        # Every one of those must divide by base_power under SYSTEM_BASE - the contract this
        # PR exists to guarantee: GenericConstraint.rhs and FCASTrapezium track PSY's units
        # base exactly like a native PSY device field does, instead of silently staying MW.
        set_units_base_system!(sys, "SYSTEM_BASE")
        try
            @test get_rhs(gc) ≈ rhs_mw / base_power
            limits_pu = get_active_power_limits(sundance)
            @test limits_pu.max ≈ limits_mw.max / base_power
            trapezium_pu = only(get_fcas_trapezium(sundance, BidType.RAISE6SEC, start_date, 1))
            @test get_max_avail(trapezium_pu) ≈ get_max_avail(trapezium_mw) / base_power
        finally
            set_units_base_system!(sys, "NATURAL_UNITS")
        end

        # Switching back reproduces the original MW/$ values exactly.
        @test get_rhs(gc) == rhs_mw
        @test get_active_power_limits(sundance).max == limits_mw.max
    end

    @testset "JSON round-trip" begin
        mktpath = mktempdir()
        json_path = joinpath(mktpath, "sys.json")
        to_json(sys, json_path; force = true)
        sys2 = System(json_path)
        assert_coverage_matrix(sys2)
    end
end
