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
end
