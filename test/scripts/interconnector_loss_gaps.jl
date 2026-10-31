if !isdefined(@__MODULE__, :InterconnectorLossGaps)
    include(joinpath(@__DIR__, "..", "..", "scripts", "interconnector_loss_gaps.jl"))
end
using .InterconnectorLossGaps: loss_gap_table

@testset "interconnector loss gaps on a saved replay" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 10)
    folder = mktempdir()
    result = replicate_range(db, t1, t2; output_dir = folder, parts = AEMS.REPLICATION_PARTS)
    @test :losses in AEMS.REPLICATION_PARTS && nrow(result.chunks) == 1

    sys = workflow_test_system(db, t1:Minute(5):(t2 + Minute(10)))
    table = loss_gap_table(only(result.results), sys)
    @test names(table) == ["interconnector", "DateTime", "flow_mw", "solved_loss_mw", "curve_loss_mw", "gap_mw", "weighted_loss_price"]
    @test !isempty(table) && Set(table.DateTime) == Set([t1, t2])
    @test all(isfinite, table.gap_mw) && all(<(1.0e-3), abs.(table.gap_mw))

    csv = joinpath(mktempdir(), "loss_gaps.csv")
    main_table = InterconnectorLossGaps.main(
        [
            "--results", folder, "--start", string(t1), "--stop", string(t2),
            "--hive", AEM_TEST_REPLAY_HIVE_DIR, "--output", csv,
        ]
    )
    @test nrow(main_table) == nrow(table)
    lines = readlines(csv)
    @test lines[1] == join(names(table), ",")
    fields = [split(line, ',') for line in lines[2:end]]
    @test length(fields) == nrow(table)
    @test all(length(f) == 7 for f in fields)
    @test Set(parse(DateTime, f[2]) for f in fields) == Set([t1, t2])
    gaps = parse.(Float64, (f[6] for f in fields))
    @test all(isfinite, gaps) && all(<(1.0e-3), abs.(gaps))

    @test_throws ArgumentError InterconnectorLossGaps.main(["--results", folder, "--start", string(t1)])
    @test_throws ArgumentError InterconnectorLossGaps.main(["--results", folder, "--start", string(t1), "--stop", string(t2), "--bogus", "x"])
    @test_throws ArgumentError InterconnectorLossGaps.main(["--results", mktempdir(), "--start", string(t1), "--stop", string(t2), "--hive", AEM_TEST_REPLAY_HIVE_DIR])
end
