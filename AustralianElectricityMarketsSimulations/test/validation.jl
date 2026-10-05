@testset "Validation harness" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    month = Date(2025, 1, 1)
    columns = [:interval, :stratum, :metric_family, :key, :ours, :published, :gap]

    @testset "validation_sample is stratified and reproducible" begin
        sample = validation_sample(db, month; n = 6, seed = 7)
        @test names(sample) == ["interval", "stratum", "intervention"]
        @test nrow(sample) == 6
        @test issorted(sample.interval)
        @test allunique(sample.interval)
        @test all(in(String.(VALIDATION_STRATA)), sample.stratum)
        @test length(unique(sample.stratum)) > 1
        @test sample == validation_sample(db, month; n = 6, seed = 7)
        @test sample.interval != validation_sample(db, month; n = 6, seed = 8).interval
        @test only(validation_sample(db, month; n = 1, strata = [:ordinary]).stratum) == "ordinary"
    end

    @testset "run_validation returns the tidy table and records failures" begin
        good = DateTime(2025, 1, 1, 0, 5, 0)
        bad = DateTime(2030, 1, 1, 0, 5, 0)
        sample = DataFrame(; interval = [good, bad], stratum = ["ordinary", "binding"])
        table = run_validation(db, sample)
        @test propertynames(table) == columns
        ok = filter(:interval => ==(good), table)
        @test Set(ok.metric_family) == Set(["regional_rop", "fcas_rop", "interconnector_flow", "interconnector_loss", "dispatch_mw"])
        @test all(==("ordinary"), ok.stratum)
        @test all(r -> ismissing(r.gap) || r.gap == r.ours - r.published, eachrow(ok))
        # IC6 is unavailable, so it has a published flow but no solved one.
        ic6 = only(filter(r -> r.metric_family == "interconnector_flow" && r.key == "IC6", ok))
        @test ismissing(ic6.ours) && ismissing(ic6.gap)
        failure = only(filter(:interval => ==(bad), table))
        @test failure.metric_family == "failure" && failure.stratum == "binding"
        @test !isempty(failure.key)

        summary = validation_summary(table)
        @test "overall" in summary.stratum
        @test Set(names(summary)) == Set(["stratum", "metric_family", "n", "n_missing", "median", "p90", "max", "n_above"])
        @test only(filter(r -> r.metric_family == "failure" && r.stratum == "binding", summary)).n == 0
    end

    @testset "complementary slackness reads published data only" begin
        range = DateTime(2025, 1, 1, 0, 5, 0):Minute(5):DateTime(2025, 1, 1, 1, 0, 0)
        cs = complementary_slackness_table(db, range)
        @test propertynames(cs) == columns
        @test all(in(["cs_violation_mw", "cs_units_violating"]), cs.metric_family)
        @test all(>=(0), skipmissing(cs.gap))
        flags = read_constraint_flags(db, range)
        @test names(flags) == ["SETTLEMENTDATE", "binding", "violated"]
    end
end
