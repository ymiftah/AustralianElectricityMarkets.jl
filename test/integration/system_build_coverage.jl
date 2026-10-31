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
        sys = augmented_pscb_system()
        set_fcas_bids!(sys, db, date_range)
        give_generator_market_bid_costs!(sys)
        set_fcas_service_bids!(sys, db, date_range)
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
                rhs_series = get_time_series_values(SingleTimeSeries, gc, "rhs")
                invoked_series = get_time_series_values(SingleTimeSeries, gc, "invoked")
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
            invoked = get_time_series_values(SingleTimeSeries, n_partial, "invoked")
            rhs = get_time_series_values(SingleTimeSeries, n_partial, "rhs")
            @test invoked == [fill(0.0, 10); fill(1.0, 15)]
            @test all(==(rhs[10]), rhs[1:10])
            @test rhs[11:25] ≈ [(40.0 + 0.1 * i) / get_base_power(sys) for i in 10:24]

            v1 = get_component(GenericConstraint, sys, vname("N_VERSIONED_LIMIT", 1))
            v2 = get_component(GenericConstraint, sys, vname("N_VERSIONED_LIMIT", 2))
            @test (get_factor(only(get_terms(v1))), get_factor(only(get_terms(v2)))) == (1.0, 2.0)
            @test (get_sense(v1), get_sense(v2)) == (ConstraintSense.LE, ConstraintSense.GE)
            @test get(v1.ext, "gencon_id", nothing) == get(v2.ext, "gencon_id", nothing) == "N_VERSIONED_LIMIT"

            bat = get_component(EnergyReservoirStorage, sys, "BAT1")
            @test has_time_series(bat, SingleTimeSeries, fcas_offer_series_name(fcas_service(bat, BidType.RAISEREG), false))
            @test has_time_series(bat, SingleTimeSeries, "fcas_trapezium_RAISEREG")
            @test has_time_series(bat, SingleTimeSeries, fcas_offer_series_name(fcas_service(bat, BidType.RAISEREG), true))
            @test has_time_series(bat, SingleTimeSeries, "fcas_trapezium_RAISEREG_decremental")
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
            # RAISE6SEC is a contingency market: its trapezium carries no ramp rates (stored as NaN).
            alta = get_component(ThermalStandard, sys, "Alta")
            @test isnothing(get_ramp_up_rate(only(AustralianElectricityMarkets._get_fcas_trapezium(alta, BidType.RAISE6SEC, start_date, 1))))
            @test isnothing(get_ramp_down_rate(only(AustralianElectricityMarkets._get_fcas_trapezium(alta, BidType.RAISE6SEC, start_date, 1))))
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

    @testset "unit contract: per-unit under SYSTEM_BASE, native MW/\$ under NATURAL_UNITS" begin
        gc = get_component(GenericConstraint, sys, vname("F_R1_RAISE6SEC"))
        sundance = get_component(ThermalStandard, sys, "Sundance")
        base_power = get_base_power(sys)

        # augmented_pscb_system() leaves sys in NATURAL_UNITS - same MW/$ ranges the
        # pre-PR-1.12 contract asserted directly off the stored fields.
        @test get_units_base(sys) == "NATURAL_UNITS"
        rhs_mw = PowerSystems.get_value(gc, Val(:rhs), Val(:mva))
        limits_mw = get_active_power_limits(sundance)
        trapezium_mw = only(AustralianElectricityMarkets._get_fcas_trapezium(sundance, BidType.RAISE6SEC, start_date, 1))
        @test 10.0 <= rhs_mw <= 200.0
        @test 10.0 <= limits_mw.max <= 500.0
        @test 10.0 <= get_max_avail(trapezium_mw) <= 500.0

        # Every one of those must divide by base_power under SYSTEM_BASE - the contract this
        # PR exists to guarantee: GenericConstraint.rhs and FCASTrapezium track PSY's units
        # base exactly like a native PSY device field does, instead of silently staying MW.
        set_units_base_system!(sys, "SYSTEM_BASE")
        try
            @test PowerSystems.get_value(gc, Val(:rhs), Val(:mva)) ≈ rhs_mw / base_power
            limits_pu = get_active_power_limits(sundance)
            @test limits_pu.max ≈ limits_mw.max / base_power
            trapezium_pu = only(AustralianElectricityMarkets._get_fcas_trapezium(sundance, BidType.RAISE6SEC, start_date, 1))
            @test get_max_avail(trapezium_pu) ≈ get_max_avail(trapezium_mw) / base_power
        finally
            set_units_base_system!(sys, "NATURAL_UNITS")
        end

        # Switching back reproduces the original MW/$ values exactly.
        @test PowerSystems.get_value(gc, Val(:rhs), Val(:mva)) == rhs_mw
        @test get_active_power_limits(sundance).max == limits_mw.max

        # FCAS values are per-unit of the system base; a device's own fields are per-unit of
        # its base_power. Under DEVICE_BASE those read as the same number meaning different
        # MW, so reading FCAS there must throw rather than return a mislabelled value.
        @test get_base_power(sundance) != base_power
        set_units_base_system!(sys, "DEVICE_BASE")
        try
            @test_throws ArgumentError AustralianElectricityMarkets._get_fcas_trapezium(
                sundance, BidType.RAISE6SEC, start_date, 1,
            )
        finally
            set_units_base_system!(sys, "NATURAL_UNITS")
        end
        @test get_max_avail(only(AustralianElectricityMarkets._get_fcas_trapezium(sundance, BidType.RAISE6SEC, start_date, 1))) ==
            get_max_avail(trapezium_mw)
    end

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
            @test PowerSystems.get_value(gc2, Val(:rhs), Val(:mva)) == PowerSystems.get_value(gc, Val(:rhs), Val(:mva))
            @test get_constraint_weight(gc2) == get_constraint_weight(gc)
            @test get_ext(gc2) == get_ext(gc)
        end
    end
end
