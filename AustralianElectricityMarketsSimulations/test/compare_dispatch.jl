@testset "Dispatch comparison" begin
    from, to = Date(2026, 6, 1), Date(2026, 6, 30)

    @testset "comparison_sample is seeded, bounded to K market days and on the 5-minute grid" begin
        s = comparison_sample(from, to; n = 100, seed = 3, days = 4)
        @test s == comparison_sample(from, to; n = 100, seed = 3, days = 4)
        @test s != comparison_sample(from, to; n = 100, seed = 4, days = 4)
        @test length(s) == 100 && allunique(s) && issorted(s)
        @test all(t -> mod(Dates.value(t - DateTime(2026, 6, 1)), Dates.value(Minute(5))) == 0, s)
        @test all(t -> from <= AEMS._market_day(t) <= to, s)
        @test length(unique(AEMS._market_day.(s))) <= 4
        @test comparison_download_mb(s) == NEMDE_DAY_ZIP_MB * length(unique(AEMS._market_day.(s)))
        # more intervals than the chosen days hold: all of them, once each
        all_two = comparison_sample(from, to; n = 10_000, days = 2)
        @test length(all_two) == 2 * 288 && allunique(all_two)
        @test length(comparison_sample(from, from; n = 5, days = 10)) == 5
        @test_throws ArgumentError comparison_sample(to, from)
    end

    @testset "comparison_intervals covers whole market days" begin
        r = comparison_intervals(Date(2026, 6, 1), Date(2026, 6, 2))
        @test length(r) == 2 * 288
        @test first(r) == DateTime(2026, 6, 1, 4, 5) && last(r) == DateTime(2026, 6, 3, 4, 0)
        @test AEMS._market_day(first(r)) == Date(2026, 6, 1) && AEMS._market_day(last(r)) == Date(2026, 6, 2)
    end

    t1, t2 = DateTime(2026, 6, 3, 15), DateTime(2026, 6, 3, 15, 5)
    aemsim = aemsim_long(
        DataFrame(;
            interval = [t1, t1, t1, t1, t2, t1],
            metric_family = ["regional_rop", "fcas_rop", "interconnector_flow", "dispatch_mw", "regional_rop", "failure"],
            key = ["NSW1", "TAS1/BidType.RAISEREG = 3", "NSW1-QLD1", "DUID1", "NSW1", "boom"],
            ours = [10.0, 5.0, 100.0, 53.0, 7.0, missing],
            published = [10.4, 5.0, 90.0, 50.2, 20.0, missing],
        )
    )
    nempy_dir = mktempdir()
    mkpath(joinpath(nempy_dir, nempy_tag(t1)))
    write(joinpath(nempy_dir, nempy_tag(t1), "price_comparison.csv"), "region,nempy_price,aemo_ROP,service\nNSW1,10.1,10.4,ENERGY\nTAS1,9.0,5.0,RAISEREG\n")
    write(joinpath(nempy_dir, nempy_tag(t1), "interconnector_comparison.csv"), "interconnector,flow,losses,MWFLOW,MWLOSSES\nNSW1-QLD1,98.0,1.0,90.0,1.5\n")
    write(joinpath(nempy_dir, nempy_tag(t1), "unit_comparison.csv"), "unit,nempy,aemo,service\nDUID1,50.1,50.2,TOTALCLEARED\nDUID1,3.0,3.0,RAISEREG\n")

    @testset "tidy readers" begin
        @test aemsim.key == ["NSW1", "TAS1/RAISEREG", "NSW1-QLD1", "DUID1", "NSW1"]
        nempy = read_nempy_interval(nempy_dir, t1)
        @test Set(nempy.metric_group) == Set(COMPARISON_GROUPS)
        @test nrow(read_nempy_interval(nempy_dir, t2)) == 0
        @test nempy_stamp(t1) == "2026/06/03 15:00:00" && nempy_tag(t1) == "20260603_150000"
        path = write_comparison_csv(joinpath(mktempdir(), "x.csv"), DataFrame(; a = ["p,q", "r\"s"], b = [1.5, missing]))
        back = read_comparison_csv(path)
        @test back.a == ["p,q", "r\"s"] && ismissing(back.b[2]) && back.b[1] == "1.5"
        write_comparison_csv(path, DataFrame(; a = ["t"], b = [2.0]); append = true)
        @test nrow(read_comparison_csv(path)) == 3
    end

    long = comparison_long(aemsim, read_nempy_interval(nempy_dir, t1))

    @testset "comparison_long joins the sources against NEMDE" begin
        @test names(long) == ["interval", "metric_group", "key", "nemde", "nempy", "aemsim", "gap_nempy", "gap_aemsim"]
        @test nrow(long) == 6
        row = only(filter(r -> r.metric_group == "regional_rop" && r.interval == t1, long))
        @test row.nemde == 10.4 && row.nempy == 10.1 && row.aemsim == 10.0
        @test row.gap_nempy ≈ -0.3 && row.gap_aemsim ≈ -0.4
        # AEMSim-only row: no nempy value, so no nempy gap
        solo = only(filter(r -> r.interval == t2, long))
        @test ismissing(solo.nempy) && ismissing(solo.gap_nempy) && solo.gap_aemsim ≈ -13.0
        # nempy-only row keeps nempy's own published value
        loss = only(filter(r -> r.metric_group == "interconnector_loss", long))
        @test ismissing(loss.aemsim) && loss.nemde == 1.5 && loss.gap_nempy ≈ -0.5
    end

    @testset "classification" begin
        by = Dict(r.metric_group => r.class for r in eachrow(comparison_classify(long)))
        @test by["regional_rop"] == "both_match"
        @test by["fcas_rop"] == "aemsim_only"
        @test by["interconnector_flow"] == "both_off_equal"
        @test by["dispatch_mw"] == "nempy_only"
        @test !haskey(by, "interconnector_loss")
        neither = DataFrame(;
            interval = [t1], metric_group = ["regional_rop"], key = ["X"], nemde = [0.0], nempy = [10.0], aemsim = [-10.0],
            gap_nempy = [10.0], gap_aemsim = [-10.0],
        )
        @test only(comparison_classify(neither).class) == "neither"
    end

    @testset "summary and report" begin
        s = comparison_summary(long)
        get_(m, col) = only(s[s.metric .== m, col])
        @test get_("regional_rop_rows", :aemsim) == 2
        @test get_("regional_rop_max_gap", :aemsim) ≈ 13.0
        @test get_("regional_rop_max_gap", :nempy) ≈ 0.3
        @test get_("regional_rop_rows_within_tolerance", :aemsim) == 1
        @test get_("fcas_rop_max_gap_incl_tas1", :nempy) ≈ 4.0
        @test ismissing(get_("fcas_rop_max_gap_excl_tas1", :nempy))
        @test get_("interconnector_flow_share_within_tolerance", :aemsim) == 0.0
        @test get_("dispatch_mw_sum_of_gaps", :aemsim) ≈ 2.8
        @test get_("dispatch_mw_missing_share", :aemsim) == 0.0
        # no nempy results at all: its column is missing, AEMSim's is intact
        s2 = comparison_summary(comparison_long(aemsim, copy(AEMS._EMPTY_NEMPY)))
        @test all(ismissing, s2.nempy) && !all(ismissing, s2.aemsim)

        worst = comparison_worst(long; n = 1)
        @test only(filter(r -> r.metric_group == "regional_rop" && r.source == "aemsim", worst)).gap ≈ -13.0

        status = DataFrame(;
            interval = [t1, t2, t2 + Minute(5)], status = ["ok", "ok", "failed"],
            seconds = [10.0, 20.0, missing], message = [missing, missing, "infeasible"],
        )
        skipped = DataFrame(; interval = [t1, t1, t2], constraint = ["A", "B", "A"], reason = [:unknown_duid, :unknown_duid, :no_definition])
        md = comparison_markdown(long, status; skipped)
        @test occursin("failed: 1", md) && occursin("infeasible", md)
        @test occursin("regional_rop_mean_gap", md) && occursin("unknown_duid", md) && occursin("### dispatch_mw", md)
    end
end
