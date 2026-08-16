@testset "Constraint types" begin
    using AustralianElectricityMarkets
    using PowerSystems

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
