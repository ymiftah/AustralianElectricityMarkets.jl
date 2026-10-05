@testset "Single-interval replication pipeline" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    t = DateTime(2025, 1, 1, 0, 5, 0)

    @testset "published interval" begin
        published = read_published_interval(db, t)
        @test Set(published.interconnectors.INTERCONNECTORID) == Set(["IC$i" for i in 1:6])
        @test "BW01" in published.dispatch.DUID
        @test eltype(published.dispatch.TOTALCLEARED) <: Union{Missing, Float64}
    end

    @testset "replicate_interval builds, solves and compares" begin
        sys = replication_system(db, t)
        # The mock generic constraints reference IC1, which the mock marks unavailable.
        PSY.set_available!(PSY.get_component(PSY.AreaInterchange, sys, "IC1"), true)
        result = replicate_interval(sys, db, t)
        @test result.model isa PSI.DecisionModel
        comparison = result.comparison
        for name in (:prices, :dispatch, :interconnectors, :fcas_prices)
            @test !isempty(getproperty(comparison, name))
        end
        @test issubset(Set(["NSW1", "QLD1", "SA1", "TAS1", "VIC1"]), Set(comparison.prices.REGIONID))
        @test all(isfinite, comparison.prices.RRP_solved)
        @test hasproperty(comparison.dispatch, :TOTALCLEARED_published)
    end
end
