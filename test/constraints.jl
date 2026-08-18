@testset "Constraint types" begin
    using AustralianElectricityMarkets
    using PowerSystems

    @testset "_modal_row_count tie-breaking" begin
        # Plain mode, no tie.
        @test AustralianElectricityMarkets._modal_row_count([12, 12, 12, 6]) == 12
        # Tallies tie 3-vs-3 between a full-coverage count (12) and a partial one (6): must
        # prefer the larger count, the safer default against reintroducing the short-series
        # crash the :partial_interval_coverage check exists to prevent.
        @test AustralianElectricityMarkets._modal_row_count([12, 12, 12, 6, 6, 6]) == 12
        @test AustralianElectricityMarkets._modal_row_count([100, 100, 3, 3]) == 100
        # Order shouldn't matter.
        @test AustralianElectricityMarkets._modal_row_count([6, 12, 6, 12, 6, 12]) == 12
    end

    @testset "ConstraintTerm construction and accessors" begin
        ut = UnitTerm("BW01", BidType.RAISE6SEC, 1.0)
        @test get_duid(ut) == "BW01"
        @test get_bid_type(ut) == BidType.RAISE6SEC
        @test get_factor(ut) == 1.0

        it = InterconnectorTerm("IC1", -0.5)
        @test get_interconnector(it) == "IC1"
        @test get_factor(it) == -0.5

        rt = RegionTerm("NSW1", BidType.ENERGY, 2.0)
        @test get_region(rt) == "NSW1"
        @test get_bid_type(rt) == BidType.ENERGY
        @test get_factor(rt) == 2.0

        req = FCASRequirement("NSW1", BidType.RAISEREG)
        @test get_region(req) == "NSW1"
        @test get_service(req) == BidType.RAISEREG
    end

    @testset "GenericConstraint construction and accessors" begin
        gc = GenericConstraint(;
            name = "F_TEST",
            sense = ConstraintSense.GE,
            rhs = 137.5,
            constraint_weight = 2.0,
            terms = ConstraintTerm[UnitTerm("BW01", BidType.RAISE6SEC, 1.0), InterconnectorTerm("IC1", -1.0)],
            governs = FCASRequirement[FCASRequirement("TAS1", BidType.RAISE6SEC)],
        )
        @test get_name(gc) == "F_TEST"
        @test get_available(gc) == true
        @test get_sense(gc) == ConstraintSense.GE
        @test get_rhs(gc) == 137.5
        @test get_constraint_weight(gc) == 2.0
        @test length(get_terms(gc)) == 2
        @test length(get_governs(gc)) == 1
        @test get_terms(gc)[1] isa UnitTerm

        set_available!(gc, false)
        @test get_available(gc) == false
        set_rhs!(gc, 10.0)
        @test get_rhs(gc) == 10.0
    end

    @testset "GenericConstraint JSON round-trip" begin
        sys = System(100.0)
        gc = GenericConstraint(;
            name = "F_ROUNDTRIP",
            sense = ConstraintSense.GE,
            rhs = 137.5,
            constraint_weight = 2.0,
            terms = ConstraintTerm[
                UnitTerm("BW01", BidType.RAISE6SEC, 1.0),
                InterconnectorTerm("IC1", -1.0),
                RegionTerm("NSW1", BidType.ENERGY, 0.5),
            ],
            governs = FCASRequirement[FCASRequirement("TAS1", BidType.RAISE6SEC), FCASRequirement("TAS1", BidType.RAISE5MIN)],
            ext = Dict{String, Any}("description" => "test constraint"),
        )
        add_component!(sys, gc)

        mktpath = mktempdir()
        json_path = joinpath(mktpath, "sys.json")
        to_json(sys, json_path)
        sys2 = System(json_path)

        gc2 = get_component(GenericConstraint, sys2, "F_ROUNDTRIP")
        @test !isnothing(gc2)
        @test get_sense(gc2) == ConstraintSense.GE
        @test get_rhs(gc2) == 137.5
        @test get_constraint_weight(gc2) == 2.0
        @test length(get_terms(gc2)) == 3
        @test length(get_governs(gc2)) == 2

        unit_term = only(filter(t -> t isa UnitTerm, get_terms(gc2)))
        @test get_duid(unit_term) == "BW01"
        @test get_bid_type(unit_term) == BidType.RAISE6SEC
        ic_term = only(filter(t -> t isa InterconnectorTerm, get_terms(gc2)))
        @test get_interconnector(ic_term) == "IC1"
        region_term = only(filter(t -> t isa RegionTerm, get_terms(gc2)))
        @test get_region(region_term) == "NSW1"

        @test all(r -> get_region(r) == "TAS1", get_governs(gc2))
        @test Set(get_service.(get_governs(gc2))) == Set([BidType.RAISE6SEC, BidType.RAISE5MIN])
    end
end

@testset "Constraint readers against mock data" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates
    using DataFrames

    hive_dir = AEM_TEST_HIVE_DIR
    config = HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(config)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))

    @testset "read_invoked_constraints" begin
        invoked = read_invoked_constraints(db, date_range)
        @test !isempty(invoked)
        @test "N_BAYSW_THERMAL" in invoked.GENCONID
        @test "N_PHANTOM_TEST" in invoked.GENCONID
        f_raise6sec_nsw1 = subset(invoked, :GENCONID => ByRow(==("F_NSW1_RAISE6SEC")))
        sort!(f_raise6sec_nsw1, :SETTLEMENTDATE)
        # RHS = requirement_mw("RAISE6SEC") + 0.1*i = 50.0 + 0.1*i, i = 0..12 over this range
        @test isapprox(first(f_raise6sec_nsw1.RHS), 50.0; atol = 1.0e-9)
        @test issorted(f_raise6sec_nsw1.RHS)  # confirms the RHS actually varies per interval
        @test all(==(DateTime(2025, 1, 1)), f_raise6sec_nsw1.GENCONID_EFFECTIVEDATE)
        @test all(==(1), f_raise6sec_nsw1.GENCONID_VERSIONNO)
    end

    @testset "read_constraint_definitions" begin
        invoked = read_invoked_constraints(db, date_range)
        versions = unique(select(invoked, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
        defs = read_constraint_definitions(db, versions)
        @test !isempty(defs)
        thermal = only(subset(defs, :GENCONID => ByRow(==("N_BAYSW_THERMAL"))))
        @test thermal.CONSTRAINTTYPE == ">="
        @test thermal.GENERICCONSTRAINTWEIGHT == 1.0
        @test thermal.CONSTRAINTVALUE == 100.0
        raise6sec_nsw1 = only(subset(defs, :GENCONID => ByRow(==("F_NSW1_RAISE6SEC"))))
        @test raise6sec_nsw1.CONSTRAINTVALUE == 50.0
    end

    @testset "read_constraint_terms" begin
        invoked = read_invoked_constraints(db, date_range)
        versions = unique(select(invoked, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
        terms = read_constraint_terms(db, versions, date_range)
        @test !isempty(terms)

        # F_VIC1_RAISE6SEC expands to 4 UnitTerms - every DUID behind CP_BAYSW (BW01-04)
        vic1_terms = subset(terms, :GENCONID => ByRow(==("F_VIC1_RAISE6SEC")))
        @test nrow(vic1_terms) == 4
        @test Set(vic1_terms.KEY) == Set(["BW01", "BW02", "BW03", "BW04"])
        @test all(==("UNIT"), vic1_terms.TERM_KIND)
        @test all(==("RAISE6SEC"), vic1_terms.BIDTYPE)

        # N_PHANTOM_TEST's only term references PHANTOM1, a DUDETAILSUMMARY-only DUID
        phantom_terms = subset(terms, :GENCONID => ByRow(==("N_PHANTOM_TEST")))
        @test nrow(phantom_terms) == 1
        @test only(phantom_terms.KEY) == "PHANTOM1"

        # F_NSW1_RAISEREG has both a UNIT term (its own DUID) and a REGION term
        raisereg_terms = subset(terms, :GENCONID => ByRow(==("F_NSW1_RAISEREG")))
        @test "REGION" in raisereg_terms.TERM_KIND

        # F_NSW1_RAISE6SEC additionally nets IC1
        ic_terms = subset(terms, :GENCONID => ByRow(==("F_NSW1_RAISE6SEC")), :TERM_KIND => ByRow(==("INTERCONNECTOR")))
        @test nrow(ic_terms) == 1
        @test only(ic_terms.KEY) == "IC1"
        @test only(ic_terms.FACTOR) == -1.0
    end

    @testset "read_constraint_governs" begin
        governs = read_constraint_governs(db, date_range)
        @test !isempty(governs)
        @test "N_BAYSW_THERMAL" ∉ governs.GENCONID  # pure network constraint
        @test "N_PHANTOM_TEST" ∉ governs.GENCONID
        raise6sec_nsw1 = subset(governs, :GENCONID => ByRow(==("F_NSW1_RAISE6SEC")))
        @test nrow(raise6sec_nsw1) == 1
        @test only(raise6sec_nsw1.REGIONID) == "NSW1"
        @test only(raise6sec_nsw1.BIDTYPE) == BidType.RAISE6SEC
    end
end

@testset "add_nem_constraints!" begin
    hive_dir = AEM_TEST_HIVE_DIR
    config = HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(config)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))

    sys = nem_system(db, RegionalNetworkConfiguration())
    added, skipped = add_nem_constraints!(sys, db, date_range)

    @test "F_VIC1_RAISE6SEC" in added
    @test "N_BAYSW_THERMAL" in added
    @test "N_PHANTOM_TEST" ∉ added
    @test skipped["N_PHANTOM_TEST"] == :unknown_duid

    # N_PARTIAL_COVERAGE is only invoked in DISPATCHCONSTRAINT for every other interval
    # (6 of 12 rows over this date_range) - fewer than the modal 12-row coverage every other
    # invoked constraint has, so it must be skipped rather than added with a short "rhs"
    # series that would fail PSY's cross-component time-series horizon check.
    @test "N_PARTIAL_COVERAGE" ∉ added
    @test skipped["N_PARTIAL_COVERAGE"] == :partial_interval_coverage

    gc = get_component(GenericConstraint, sys, "F_VIC1_RAISE6SEC")
    @test !isnothing(gc)
    @test get_sense(gc) == ConstraintSense.GE
    @test length(get_terms(gc)) == 4  # one UnitTerm per DUID behind CP_BAYSW
    @test length(get_governs(gc)) == 1
    @test only(get_governs(gc)) == FCASRequirement("VIC1", BidType.RAISE6SEC)

    network_gc = get_component(GenericConstraint, sys, "N_BAYSW_THERMAL")
    @test isempty(get_governs(network_gc))  # pure network constraint
    @test !isempty(get_terms(network_gc))

    nsw1_raise6sec = get_component(GenericConstraint, sys, "F_NSW1_RAISE6SEC")
    @test any(t -> t isa InterconnectorTerm && get_interconnector(t) == "IC1", get_terms(nsw1_raise6sec))

    rhs_ts = get_time_series(Deterministic, gc, "rhs")
    @test !isnothing(rhs_ts)
    rhs_values = first(values(get_data(rhs_ts)))
    @test issorted(rhs_values)  # RHS = 50.0 + 0.1*i, confirmed time-varying in Task 8

    @test !has_time_series(gc, Deterministic, "lhs")  # include_solution defaults false

    added2, _ = add_nem_constraints!(nem_system(db, RegionalNetworkConfiguration()), db, date_range; include_solution = true)
    @test "F_VIC1_RAISE6SEC" in added2
end
