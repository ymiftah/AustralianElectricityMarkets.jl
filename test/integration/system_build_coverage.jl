@testset "System build coverage and JSON round-trip" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates
    using DataFrames

    # This test builds one System through the PSCB fixture's manual builder-call sequence
    # (nem_system can't be used here - see pscb_nemweb_data.jl's top-of-file comment), asserts every constraint/FCAS/loss input the
    # System should carry, then re-asserts the same coverage after a JSON round-trip.
    config = HiveConfiguration(hive_location = AEM_TEST_PSCB_HIVE_DIR, filesystem = "file")
    db = aem_connect(config)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(2) + Minute(5))
    vname(gencon_id, version = 1) = "$gencon_id@2025-01-01#$version"

    function build_system()
        sys = nem_pscb_system()
        set_market_bids!(sys, db, date_range)
        build_constraints!(sys, db, date_range)
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
                rhs_series = _constraint_series(gc, :rhs)
                invoked_series = _constraint_series(gc, :invoked)
                @test length(rhs_series) == length(date_range) - 1
                @test length(invoked_series) == length(date_range) - 1
            end
        end

        @testset "constraint LHS: RegionTerm devices" begin
            gc = get_component(GenericConstraint, sys, vname("F_R1_RAISE6SEC"))
            region_term = only(filter(t -> t isa RegionTerm, get_terms(gc)))
            @test !isempty(get_devices(region_term))
        end

        @testset "constraint terms, senses, requirements and series" begin
            f_r1 = get_component(GenericConstraint, sys, vname("F_R1_RAISE6SEC"))
            @test Set(get_duid.(filter(t -> t isa UnitTerm, get_terms(f_r1)))) == Set(["Alta", "Brighton"])
            @test get_factor(only(filter(t -> t isa RegionTerm, get_terms(f_r1)))) == 1.0
            @test only(get_fcas_requirements(f_r1)) == FCASRequirement("1", BidType.RAISE6SEC)

            f_r2 = get_component(GenericConstraint, sys, vname("F_R2_LOWERREG"))
            @test get_duid(only(filter(t -> t isa UnitTerm, get_terms(f_r2)))) == "Solitude"
            @test get_region(only(filter(t -> t isa RegionTerm, get_terms(f_r2)))) == "2"
            @test only(get_fcas_requirements(f_r2)) == FCASRequirement("2", BidType.LOWERREG)

            n_ic1 = get_component(GenericConstraint, sys, vname("N_IC1_LIMIT"))
            @test get_factor(only(filter(t -> t isa InterconnectorTerm, get_terms(n_ic1)))) == -1.0
            @test Set(get_duid.(filter(t -> t isa UnitTerm, get_terms(n_ic1)))) == Set(["Park City", "Sundance"])
            @test all(==(BidType.ENERGY), get_bid_type.(filter(t -> t isa UnitTerm, get_terms(n_ic1))))

            n_hydro = get_component(GenericConstraint, sys, vname("N_HYDRO_LIMIT"))
            @test Set(get_duid.(filter(t -> t isa UnitTerm, get_terms(n_hydro)))) ==
                Set(["HydroDispatch1", "HydroDispatch2", "HydroDispatch3"])

            n_partial = get_component(GenericConstraint, sys, vname("N_PARTIAL"))
            @test get_duid(only(filter(t -> t isa UnitTerm, get_terms(n_partial)))) == "SOLAR1"
            invoked = _constraint_series(n_partial, :invoked)
            rhs = _constraint_series(n_partial, :rhs)
            @test invoked == [fill(0.0, 10); fill(1.0, 15)]
            @test all(==(rhs[10]), rhs[1:10])
            @test rhs[11:25] ≈ [40.0 + 0.1 * i for i in 10:24]

            v1 = get_component(GenericConstraint, sys, vname("N_VERSIONED_LIMIT", 1))
            v2 = get_component(GenericConstraint, sys, vname("N_VERSIONED_LIMIT", 2))
            @test (get_factor(only(get_terms(v1))), get_factor(only(get_terms(v2)))) == (1.0, 2.0)
            @test (get_sense(v1), get_sense(v2)) == (ConstraintSense.LE, ConstraintSense.GE)
            @test get_gencon_id(v1) == get_gencon_id(v2) == "N_VERSIONED_LIMIT"
            @test (get_version_no(v1), get_version_no(v2)) == (1, 2)
            @test (get_effective_date(v1), get_effective_date(v2)) ==
                (DateTime(2025, 1, 1), DateTime(2025, 1, 1))
            @test (get_limit_type(v1), get_limit_type(v2)) == ("THERMAL", "THERMAL")
            @test (get_source(v1), get_source(v2)) == ("pscb", "pscb")
            @test isempty(get_ext(v1)) && isempty(get_ext(v2))
            bat = get_component(NEMStorage, sys, "BAT1")
            for direction in (AustralianElectricityMarkets.BidDirection.GEN, AustralianElectricityMarkets.BidDirection.LOAD)
                bid = only(b for b in AustralianElectricityMarkets.get_fcas_bids(get_operation_cost(bat)) if b.service == BidType.RAISEREG && b.direction == direction)
                @test has_time_series(bat, SingleTimeSeries, bid.offer_curves.name)
                @test has_time_series(bat, SingleTimeSeries, bid.trapezium.name)
            end
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
    # One station shared by two generators, attached after the build.
    station = NEMStation(; station_id = "STN1", station_name = "Station One", postcode = "3000")
    for name in ("Alta", "Brighton")
        add_supplemental_attribute!(sys, get_component(Generator, sys, name), station)
    end
    assert_coverage_matrix(sys)

    @testset "JSON round-trip" begin
        mktpath = mktempdir()
        json_path = joinpath(mktpath, "sys.json")
        to_json(sys, json_path; force = true)
        sys2 = System(json_path)
        assert_coverage_matrix(sys2)
        for name in (
                vname("F_R1_RAISE6SEC"), vname("F_R2_LOWERREG"), vname("N_IC1_LIMIT"), vname("N_HYDRO_LIMIT"),
                vname("N_PARTIAL"), vname("N_VERSIONED_LIMIT", 1), vname("N_VERSIONED_LIMIT", 2),
            )
            gc, gc2 = get_component(GenericConstraint, sys, name), get_component(GenericConstraint, sys2, name)
            @test get_sense(gc2) == get_sense(gc)
            @test _constraint_series(gc2, :rhs) == _constraint_series(gc, :rhs)
            @test get_constraint_weight(gc2) == get_constraint_weight(gc)
            @test get_ext(gc2) == get_ext(gc)
            @test get_gencon_id(gc2) == get_gencon_id(gc)
            @test get_limit_type(gc2) == get_limit_type(gc)
            @test get_source(gc2) == get_source(gc)
            @test get_effective_date(gc2) == get_effective_date(gc)
            @test get_version_no(gc2) == get_version_no(gc)
        end
        for name in ("Alta", "Brighton")
            stn = only(get_supplemental_attributes(NEMStation, get_component(Generator, sys2, name)))
            @test stn.station_id == "STN1"
            @test stn.station_name == "Station One"
            @test stn.postcode == "3000"
        end
    end
end
