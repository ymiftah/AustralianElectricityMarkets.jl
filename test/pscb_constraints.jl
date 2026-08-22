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

    @testset "add_nem_constraints!" begin
        sys = augmented_pscb_system()
        added, skipped = add_nem_constraints!(sys, db, date_range)

        @test isempty(skipped)
        @test Set(added) == Set(
            [
                "F_R1_RAISE6SEC", "F_R2_LOWERREG", "N_IC1_LIMIT", "N_HYDRO_LIMIT", "N_PARTIAL",
            ]
        )

        @testset "UnitTerm 1:many connection-point expansion" begin
            gc = get_component(GenericConstraint, sys, "F_R1_RAISE6SEC")
            unit_terms = filter(t -> t isa UnitTerm, get_terms(gc))
            @test Set(get_duid.(unit_terms)) == Set(["Alta", "Brighton"])
            @test all(==(BidType.RAISE6SEC), get_bid_type.(unit_terms))

            region_term = only(filter(t -> t isa RegionTerm, get_terms(gc)))
            @test get_region(region_term) == "1"
            @test get_bid_type(region_term) == BidType.RAISE6SEC
        end

        @testset "InterconnectorTerm resolves" begin
            gc = get_component(GenericConstraint, sys, "N_IC1_LIMIT")
            ic_term = only(filter(t -> t isa InterconnectorTerm, get_terms(gc)))
            @test get_interconnector(ic_term) == "IC1"
            @test get_factor(ic_term) == -1.0
            unit_terms = filter(t -> t isa UnitTerm, get_terms(gc))
            @test Set(get_duid.(unit_terms)) == Set(["Park City", "Sundance"])
        end

        @testset "FCAS requirements attach only where they should" begin
            f_r1 = get_component(GenericConstraint, sys, "F_R1_RAISE6SEC")
            @test only(get_fcas_requirements(f_r1)) == FCASRequirement("1", BidType.RAISE6SEC)
            f_r2 = get_component(GenericConstraint, sys, "F_R2_LOWERREG")
            @test only(get_fcas_requirements(f_r2)) == FCASRequirement("2", BidType.LOWERREG)

            for gencon_id in ("N_IC1_LIMIT", "N_HYDRO_LIMIT", "N_PARTIAL")
                gc = get_component(GenericConstraint, sys, gencon_id)
                @test isempty(get_fcas_requirements(gc))
            end
        end

        @testset "sense mapping" begin
            for gencon_id in ("F_R1_RAISE6SEC", "F_R2_LOWERREG")
                @test get_sense(get_component(GenericConstraint, sys, gencon_id)) == ConstraintSense.GE
            end
            for gencon_id in ("N_IC1_LIMIT", "N_HYDRO_LIMIT", "N_PARTIAL")
                @test get_sense(get_component(GenericConstraint, sys, gencon_id)) == ConstraintSense.LE
            end
        end

        @testset "N_PARTIAL padding" begin
            gc = get_component(GenericConstraint, sys, "N_PARTIAL")
            invoked_series = first(values(get_data(get_time_series(Deterministic, gc, "invoked"))))
            rhs_series = first(values(get_data(get_time_series(Deterministic, gc, "rhs"))))

            @test length(invoked_series) == length(rhs_series) == 25  # full 0:24 grid
            @test invoked_series[1:10] == fill(0.0, 10)   # intervals 0..9: not yet invoked
            @test invoked_series[11:25] == fill(1.0, 15)  # intervals 10..24: invoked

            # rhs is carried forward before interval 10 and real thereafter.
            @test all(==(rhs_series[10]), rhs_series[1:10])
            @test rhs_series[11:25] ≈ [40.0 + 0.1 * i for i in 10:24]
        end

        @testset "rhs varies across intervals for a fully-covered constraint" begin
            gc = get_component(GenericConstraint, sys, "F_R1_RAISE6SEC")
            rhs_series = first(values(get_data(get_time_series(Deterministic, gc, "rhs"))))
            @test length(rhs_series) == 25
            @test rhs_series ≈ [30.0 + 0.1 * i for i in 0:24]
            @test issorted(rhs_series)  # confirms it isn't flat
        end
    end

    @testset "set_fcas_bids!" begin
        sys = augmented_pscb_system()
        set_fcas_bids!(sys, db, date_range)

        @testset "thermal unit gets curve and trapezium series" begin
            gen = get_component(ThermalStandard, sys, "Alta")
            @test has_time_series(gen, Deterministic, "fcas_curve_RAISE6SEC")
            @test has_time_series(gen, Deterministic, "fcas_trapezium_RAISE6SEC")
        end

        @testset "SOLAR1 (RenewableDispatch) gets curve and trapezium series" begin
            solar = get_component(RenewableDispatch, sys, "SOLAR1")
            @test has_time_series(solar, Deterministic, "fcas_curve_RAISE6SEC")
            @test has_time_series(solar, Deterministic, "fcas_trapezium_RAISE6SEC")
        end

        @testset "BAT1 gets both incremental and decremental series" begin
            bat = get_component(EnergyReservoirStorage, sys, "BAT1")
            @test has_time_series(bat, Deterministic, "fcas_curve_RAISEREG")
            @test has_time_series(bat, Deterministic, "fcas_trapezium_RAISEREG")
            @test has_time_series(bat, Deterministic, "fcas_curve_RAISEREG_decremental")
            @test has_time_series(bat, Deterministic, "fcas_trapezium_RAISEREG_decremental")
        end

        @testset "decremental series is storage-only" begin
            gen = get_component(ThermalStandard, sys, "Alta")
            @test !has_time_series(gen, Deterministic, "fcas_curve_RAISEREG_decremental")
            @test !has_time_series(gen, Deterministic, "fcas_trapezium_RAISEREG_decremental")
        end
    end

    @testset "full system JSON round-trip" begin
        sys = augmented_pscb_system()
        add_nem_constraints!(sys, db, date_range)
        set_fcas_bids!(sys, db, date_range)

        constraint_names = ["F_R1_RAISE6SEC", "F_R2_LOWERREG", "N_IC1_LIMIT", "N_HYDRO_LIMIT", "N_PARTIAL"]

        mktpath = mktempdir()
        json_path = joinpath(mktpath, "sys.json")
        to_json(sys, json_path; force = true)
        sys2 = System(json_path)

        @testset "GenericConstraints retrievable with scalar fields preserved" begin
            for name in constraint_names
                gc = get_component(GenericConstraint, sys, name)
                gc2 = get_component(GenericConstraint, sys2, name)
                @test !isnothing(gc2)
                @test get_sense(gc2) == get_sense(gc)
                @test get_rhs(gc2) == get_rhs(gc)
                @test get_constraint_weight(gc2) == get_constraint_weight(gc)
                @test get_ext(gc2) == get_ext(gc)
            end
        end

        @testset "terms keep concrete type and payload" begin
            f_r1 = get_component(GenericConstraint, sys2, "F_R1_RAISE6SEC")
            unit_terms = filter(t -> t isa UnitTerm, get_terms(f_r1))
            @test Set(get_duid.(unit_terms)) == Set(["Alta", "Brighton"])
            @test all(==(BidType.RAISE6SEC), get_bid_type.(unit_terms))
            @test all(==(1.0), get_factor.(unit_terms))
            region_term = only(filter(t -> t isa RegionTerm, get_terms(f_r1)))
            @test get_region(region_term) == "1"
            @test get_bid_type(region_term) == BidType.RAISE6SEC
            @test get_factor(region_term) == 1.0

            f_r2 = get_component(GenericConstraint, sys2, "F_R2_LOWERREG")
            unit_term = only(filter(t -> t isa UnitTerm, get_terms(f_r2)))
            @test get_duid(unit_term) == "Solitude"
            @test get_bid_type(unit_term) == BidType.LOWERREG
            region_term2 = only(filter(t -> t isa RegionTerm, get_terms(f_r2)))
            @test get_region(region_term2) == "2"
            @test get_bid_type(region_term2) == BidType.LOWERREG

            n_ic1 = get_component(GenericConstraint, sys2, "N_IC1_LIMIT")
            ic_term = only(filter(t -> t isa InterconnectorTerm, get_terms(n_ic1)))
            @test get_interconnector(ic_term) == "IC1"
            @test get_factor(ic_term) == -1.0
            unit_terms_ic = filter(t -> t isa UnitTerm, get_terms(n_ic1))
            @test Set(get_duid.(unit_terms_ic)) == Set(["Park City", "Sundance"])
            @test all(==(BidType.ENERGY), get_bid_type.(unit_terms_ic))

            n_hydro = get_component(GenericConstraint, sys2, "N_HYDRO_LIMIT")
            hydro_units = filter(t -> t isa UnitTerm, get_terms(n_hydro))
            @test Set(get_duid.(hydro_units)) == Set(["HydroDispatch1", "HydroDispatch2", "HydroDispatch3"])

            n_partial = get_component(GenericConstraint, sys2, "N_PARTIAL")
            partial_unit = only(filter(t -> t isa UnitTerm, get_terms(n_partial)))
            @test get_duid(partial_unit) == "SOLAR1"
        end

        @testset "FCASRequirement attaches only to the two F_ constraints" begin
            f_r1 = get_component(GenericConstraint, sys2, "F_R1_RAISE6SEC")
            @test only(get_fcas_requirements(f_r1)) == FCASRequirement("1", BidType.RAISE6SEC)
            f_r2 = get_component(GenericConstraint, sys2, "F_R2_LOWERREG")
            @test only(get_fcas_requirements(f_r2)) == FCASRequirement("2", BidType.LOWERREG)
            for name in ("N_IC1_LIMIT", "N_HYDRO_LIMIT", "N_PARTIAL")
                @test isempty(get_fcas_requirements(get_component(GenericConstraint, sys2, name)))
            end
        end

        @testset "N_PARTIAL rhs/invoked series survive exactly" begin
            gc2 = get_component(GenericConstraint, sys2, "N_PARTIAL")
            invoked_series = first(values(get_data(get_time_series(Deterministic, gc2, "invoked"))))
            rhs_series = first(values(get_data(get_time_series(Deterministic, gc2, "rhs"))))
            @test length(invoked_series) == length(rhs_series) == 25
            @test invoked_series[1:10] == fill(0.0, 10)
            @test invoked_series[11:25] == fill(1.0, 15)
            @test all(==(rhs_series[10]), rhs_series[1:10])
            @test rhs_series[11:25] ≈ [40.0 + 0.1 * i for i in 10:24]
        end

        @testset "BAT1 FCAS bid series, including decremental, survive" begin
            bat2 = get_component(EnergyReservoirStorage, sys2, "BAT1")
            @test has_time_series(bat2, Deterministic, "fcas_curve_RAISEREG")
            @test has_time_series(bat2, Deterministic, "fcas_trapezium_RAISEREG")
            @test has_time_series(bat2, Deterministic, "fcas_curve_RAISEREG_decremental")
            @test has_time_series(bat2, Deterministic, "fcas_trapezium_RAISEREG_decremental")
        end
    end
end
