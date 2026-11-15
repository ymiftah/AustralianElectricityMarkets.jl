@testset "PSCB constraints and FCAS" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_PSCB_HIVE_DIR, filesystem = "file"))
    start_date = DateTime(2025, 1, 1, 0, 0)
    # `read_invoked_constraints` excludes last(date_range), so the range runs past 02:00 to keep that interval.
    date_range = start_date:Minute(5):(start_date + Hour(2) + Minute(5))
    # Components are named by the versioned triple; every fixture version is effective 2025-01-01.
    vname(gencon_id, version = 1) = "$gencon_id@2025-01-01#$version"
    unit_duids(gc) = Set(get_duid.(filter(t -> t isa UnitTerm, get_terms(gc))))

    @testset "constraint build" begin
        sys = nem_pscb_system()
        added, skipped = build_constraints!(sys, db, date_range)
        constraint(name, version = 1) = get_component(GenericConstraint, sys, vname(name, version))

        @test isempty(skipped)
        @test Set(added) == Set(
            [
                vname("F_R1_RAISE6SEC"), vname("F_R2_LOWERREG"), vname("N_IC1_LIMIT"),
                vname("N_HYDRO_LIMIT"), vname("N_PARTIAL"),
                vname("N_VERSIONED_LIMIT", 1), vname("N_VERSIONED_LIMIT", 2),
            ]
        )

        @testset "terms: connection-point expansion, region and interconnector terms" begin
            f_r1 = constraint("F_R1_RAISE6SEC")
            @test unit_duids(f_r1) == Set(["Alta", "Brighton"])
            @test all(==(BidType.RAISE6SEC), get_bid_type.(filter(t -> t isa UnitTerm, get_terms(f_r1))))
            region_term = only(filter(t -> t isa RegionTerm, get_terms(f_r1)))
            @test (get_region(region_term), get_bid_type(region_term), get_factor(region_term)) == ("1", BidType.RAISE6SEC, 1.0)

            f_r2 = constraint("F_R2_LOWERREG")
            @test unit_duids(f_r2) == Set(["Solitude"])
            @test get_region(only(filter(t -> t isa RegionTerm, get_terms(f_r2)))) == "2"

            n_ic1 = constraint("N_IC1_LIMIT")
            ic_term = only(filter(t -> t isa InterconnectorTerm, get_terms(n_ic1)))
            @test (get_interconnector(ic_term), get_factor(ic_term)) == ("IC1", -1.0)
            @test unit_duids(n_ic1) == Set(["Park City", "Sundance"])
            @test all(==(BidType.ENERGY), get_bid_type.(filter(t -> t isa UnitTerm, get_terms(n_ic1))))

            @test unit_duids(constraint("N_HYDRO_LIMIT")) == Set(["HydroDispatch1", "HydroDispatch2", "HydroDispatch3"])
            @test unit_duids(constraint("N_PARTIAL")) == Set(["SOLAR1"])
        end

        @testset "FCAS requirements and senses" begin
            @test only(get_fcas_requirements(constraint("F_R1_RAISE6SEC"))) == FCASRequirement("1", BidType.RAISE6SEC)
            @test only(get_fcas_requirements(constraint("F_R2_LOWERREG"))) == FCASRequirement("2", BidType.LOWERREG)
            for name in ("F_R1_RAISE6SEC", "F_R2_LOWERREG")
                @test get_sense(constraint(name)) == ConstraintSense.GE
            end
            for name in ("N_IC1_LIMIT", "N_HYDRO_LIMIT", "N_PARTIAL")
                @test isempty(get_fcas_requirements(constraint(name)))
                @test get_sense(constraint(name)) == ConstraintSense.LE
            end
        end

        @testset "rhs and invoked series: full coverage and N_PARTIAL padding" begin
            @test _constraint_series(constraint("F_R1_RAISE6SEC"), :rhs) ≈ [30.0 + 0.1 * i for i in 0:24]
            invoked = _constraint_series(constraint("N_PARTIAL"), :invoked)
            rhs = _constraint_series(constraint("N_PARTIAL"), :rhs)
            @test invoked == [fill(0.0, 10); fill(1.0, 15)]
            # rhs is carried back before interval 10 and real thereafter, in MW.
            @test all(==(rhs[10]), rhs[1:10])
            @test rhs[11:25] ≈ [40.0 + 0.1 * i for i in 10:24]
        end

        @testset "N_VERSIONED_LIMIT: a mid-horizon version switch produces two complementary services" begin
            v1, v2 = constraint("N_VERSIONED_LIMIT", 1), constraint("N_VERSIONED_LIMIT", 2)
            @test get_gencon_id(v1) == get_gencon_id(v2) == "N_VERSIONED_LIMIT"
            @test (get_version_no(v1), get_version_no(v2)) == (1, 2)
            @test get_effective_date(v1) == get_effective_date(v2) == DateTime(2025, 1, 1)
            @test get_limit_type(v1) == get_limit_type(v2) == "THERMAL"
            @test get_source(v1) == get_source(v2) == "pscb"
            @test isempty(get_ext(v1)) && isempty(get_ext(v2))
            @test (get_sense(v1), get_sense(v2)) == (ConstraintSense.LE, ConstraintSense.GE)
            @test get_duid(only(get_terms(v1))) == get_duid(only(get_terms(v2))) == "BAT1"
            @test (get_factor(only(get_terms(v1))), get_factor(only(get_terms(v2)))) == (1.0, 2.0)
            @test _constraint_series(v1, :invoked) == [i < PSCB_VERSION_SWITCH_FROM ? 1.0 : 0.0 for i in 0:24]
            @test _constraint_series(v2, :invoked) == [i < PSCB_VERSION_SWITCH_FROM ? 0.0 : 1.0 for i in 0:24]
        end
    end

    @testset "set_market_bids! records FCAS bids with their series on the modelled sides only" begin
        sys = nem_pscb_system()
        set_market_bids!(sys, db, date_range)
        AEM = AustralianElectricityMarkets
        bids(device) = AEM.get_fcas_bids(AEM._nem_offer_cost(device))
        for (type, name, service, direction) in (
                (ThermalStandard, "Alta", BidType.RAISE6SEC, AEM.BidDirection.GEN),
                (RenewableDispatch, "SOLAR1", BidType.RAISE6SEC, AEM.BidDirection.GEN),
                (EnergyReservoirStorage, "BAT1", BidType.RAISEREG, AEM.BidDirection.GEN),
                (EnergyReservoirStorage, "BAT1", BidType.RAISEREG, AEM.BidDirection.LOAD),
            )
            device = get_component(type, sys, name)
            bid = only(b for b in bids(device) if b.service == service && b.direction == direction)
            @test has_time_series(device, SingleTimeSeries, bid.offer_curves.name)
            @test has_time_series(device, SingleTimeSeries, bid.trapezium.name)
        end
        # A generator's load-side bid is not modelled.
        @test !any(b -> b.direction == AEM.BidDirection.LOAD, bids(get_component(ThermalStandard, sys, "Alta")))
    end
end
