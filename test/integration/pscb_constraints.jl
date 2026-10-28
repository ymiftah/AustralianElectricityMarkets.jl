@testset "PSCB constraints and FCAS" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates
    using DataFrames

    config = HiveConfiguration(hive_location = AEM_TEST_PSCB_HIVE_DIR, filesystem = "file")
    db = aem_connect(config)
    start_date = DateTime(2025, 1, 1, 0, 0)
    # `read_invoked_constraints` filters SETTLEMENTDATE < last(date_range) (exclusive), so the
    # range must extend past 02:00 to keep the i=24 (02:00) interval in the full grid.
    date_range = start_date:Minute(5):(start_date + Hour(2) + Minute(5))

    # Every constraint in this fixture except N_VERSIONED_LIMIT has exactly one invoked
    # GENCONDATA/SPD* version, always EFFECTIVEDATE=2025-01-01, VERSIONNO=1 - see
    # create_pscb_nemweb_data. add_nem_constraints! names components by the full versioned
    # triple, so tests look components up by
    # this name rather than the bare GENCONID.
    vname(gencon_id, version = 1) = "$gencon_id@2025-01-01#$version"

    @testset "add_nem_constraints!" begin
        sys = augmented_pscb_system()
        added, skipped = add_nem_constraints!(sys, db, date_range)

        @test isempty(skipped)
        @test Set(added) == Set(
            [
                vname("F_R1_RAISE6SEC"), vname("F_R2_LOWERREG"), vname("N_IC1_LIMIT"),
                vname("N_HYDRO_LIMIT"), vname("N_PARTIAL"),
                vname("N_VERSIONED_LIMIT", 1), vname("N_VERSIONED_LIMIT", 2),
            ]
        )

        @testset "UnitTerm 1:many connection-point expansion" begin
            gc = get_component(GenericConstraint, sys, vname("F_R1_RAISE6SEC"))
            unit_terms = filter(t -> t isa UnitTerm, get_terms(gc))
            @test Set(get_duid.(unit_terms)) == Set(["Alta", "Brighton"])
            @test all(==(BidType.RAISE6SEC), get_bid_type.(unit_terms))

            region_term = only(filter(t -> t isa RegionTerm, get_terms(gc)))
            @test get_region(region_term) == "1"
            @test get_bid_type(region_term) == BidType.RAISE6SEC
        end

        @testset "InterconnectorTerm resolves" begin
            gc = get_component(GenericConstraint, sys, vname("N_IC1_LIMIT"))
            ic_term = only(filter(t -> t isa InterconnectorTerm, get_terms(gc)))
            @test get_interconnector(ic_term) == "IC1"
            @test get_factor(ic_term) == -1.0
            unit_terms = filter(t -> t isa UnitTerm, get_terms(gc))
            @test Set(get_duid.(unit_terms)) == Set(["Park City", "Sundance"])
        end

        @testset "FCAS requirements attach only where they should" begin
            f_r1 = get_component(GenericConstraint, sys, vname("F_R1_RAISE6SEC"))
            @test only(get_fcas_requirements(f_r1)) == FCASRequirement("1", BidType.RAISE6SEC)
            f_r2 = get_component(GenericConstraint, sys, vname("F_R2_LOWERREG"))
            @test only(get_fcas_requirements(f_r2)) == FCASRequirement("2", BidType.LOWERREG)

            for name in (vname("N_IC1_LIMIT"), vname("N_HYDRO_LIMIT"), vname("N_PARTIAL"))
                gc = get_component(GenericConstraint, sys, name)
                @test isempty(get_fcas_requirements(gc))
            end
        end

        @testset "sense mapping" begin
            for name in (vname("F_R1_RAISE6SEC"), vname("F_R2_LOWERREG"))
                @test get_sense(get_component(GenericConstraint, sys, name)) == ConstraintSense.GE
            end
            for name in (vname("N_IC1_LIMIT"), vname("N_HYDRO_LIMIT"), vname("N_PARTIAL"))
                @test get_sense(get_component(GenericConstraint, sys, name)) == ConstraintSense.LE
            end
        end

        @testset "N_PARTIAL padding" begin
            gc = get_component(GenericConstraint, sys, vname("N_PARTIAL"))
            base_power = get_base_power(sys)
            invoked_series = get_time_series_values(SingleTimeSeries, gc, "invoked")
            rhs_series = get_time_series_values(SingleTimeSeries, gc, "rhs")

            @test length(invoked_series) == length(rhs_series) == 25  # full 0:24 grid
            @test invoked_series[1:10] == fill(0.0, 10)   # intervals 0..9: not yet invoked
            @test invoked_series[11:25] == fill(1.0, 15)  # intervals 10..24: invoked

            # rhs is carried forward before interval 10 and real thereafter. The "rhs" series is
            # stored per-unit of sys's base power - see GenericConstraint.
            @test all(==(rhs_series[10]), rhs_series[1:10])
            @test rhs_series[11:25] ≈ [(40.0 + 0.1 * i) / base_power for i in 10:24]
        end

        @testset "rhs varies across intervals for a fully-covered constraint" begin
            gc = get_component(GenericConstraint, sys, vname("F_R1_RAISE6SEC"))
            base_power = get_base_power(sys)
            rhs_series = get_time_series_values(SingleTimeSeries, gc, "rhs")
            @test length(rhs_series) == 25
            @test rhs_series ≈ [(30.0 + 0.1 * i) / base_power for i in 0:24]
            @test issorted(rhs_series)  # confirms it isn't flat
        end

        @testset "N_VERSIONED_LIMIT: mid-horizon version switch produces two complementary services" begin
            gc_v1 = get_component(GenericConstraint, sys, vname("N_VERSIONED_LIMIT", 1))
            gc_v2 = get_component(GenericConstraint, sys, vname("N_VERSIONED_LIMIT", 2))
            @test !isnothing(gc_v1)
            @test !isnothing(gc_v2)

            # Both versions report the same bare GENCONID despite being different components.
            @test get_gencon_id(gc_v1) == "N_VERSIONED_LIMIT"
            @test get_gencon_id(gc_v2) == "N_VERSIONED_LIMIT"
            @test get_name(gc_v1) != get_name(gc_v2)

            # The changed sense and term coefficient actually differ between the two versions.
            @test get_sense(gc_v1) == ConstraintSense.LE
            @test get_sense(gc_v2) == ConstraintSense.GE
            term_v1 = only(get_terms(gc_v1))
            term_v2 = only(get_terms(gc_v2))
            @test get_duid(term_v1) == get_duid(term_v2) == "BAT1"
            @test get_factor(term_v1) == 1.0
            @test get_factor(term_v2) == 2.0

            # "invoked" series are complementary: exactly one version is 1.0 at every interval,
            # switching at PSCB_VERSION_SWITCH_FROM, never both at once.
            invoked_v1 = get_time_series_values(SingleTimeSeries, gc_v1, "invoked")
            invoked_v2 = get_time_series_values(SingleTimeSeries, gc_v2, "invoked")
            @test length(invoked_v1) == length(invoked_v2) == 25
            @test all(==(1.0), invoked_v1 .+ invoked_v2)  # exactly one is 1.0 at every interval
            @test invoked_v1 == [i < PSCB_VERSION_SWITCH_FROM ? 1.0 : 0.0 for i in 0:24]
            @test invoked_v2 == [i < PSCB_VERSION_SWITCH_FROM ? 0.0 : 1.0 for i in 0:24]
        end

        @testset "single-version constraint takes the same code path, no special-casing" begin
            # F_R1_RAISE6SEC has exactly one invoked version and produces exactly one service -
            # the version-triple loop degenerates to the old one-constraint-per-GENCONID
            # behaviour when there is only ever one version, with no separate branch for it.
            matches = filter(
                gc -> get_gencon_id(gc) == "F_R1_RAISE6SEC", collect(get_components(GenericConstraint, sys)),
            )
            @test length(matches) == 1
            @test get_name(only(matches)) == vname("F_R1_RAISE6SEC")
        end
    end

    @testset "set_fcas_bids!" begin
        sys = augmented_pscb_system()
        set_fcas_bids!(sys, db, date_range)
        give_generator_market_bid_costs!(sys)
        set_fcas_service_bids!(sys, db, date_range)

        @testset "thermal unit gets trapezium series and offer curve once it has a MarketBidCost" begin
            gen = get_component(ThermalStandard, sys, "Alta")
            @test get_operation_cost(gen) isa MarketBidCost
            @test has_time_series(gen, SingleTimeSeries, fcas_offer_series_name(fcas_service(gen, BidType.RAISE6SEC), false))
            @test has_time_series(gen, SingleTimeSeries, "fcas_trapezium_RAISE6SEC")
        end

        @testset "SOLAR1 (RenewableDispatch, zero cost) gets curve and trapezium series" begin
            solar = get_component(RenewableDispatch, sys, "SOLAR1")
            @test has_time_series(solar, SingleTimeSeries, fcas_offer_series_name(fcas_service(solar, BidType.RAISE6SEC), false))
            @test has_time_series(solar, SingleTimeSeries, "fcas_trapezium_RAISE6SEC")
        end

        @testset "BAT1 gets both incremental and decremental series" begin
            bat = get_component(EnergyReservoirStorage, sys, "BAT1")
            @test has_time_series(bat, SingleTimeSeries, fcas_offer_series_name(fcas_service(bat, BidType.RAISEREG), false))
            @test has_time_series(bat, SingleTimeSeries, "fcas_trapezium_RAISEREG")
            @test has_time_series(bat, SingleTimeSeries, fcas_offer_series_name(fcas_service(bat, BidType.RAISEREG), true))
            @test has_time_series(bat, SingleTimeSeries, "fcas_trapezium_RAISEREG_decremental")
        end

        @testset "decremental series is storage-only" begin
            gen = get_component(ThermalStandard, sys, "Alta")
            @test !has_time_series(gen, SingleTimeSeries, "fcas_trapezium_RAISEREG_decremental")
        end
    end
end
