if !isdefined(@__MODULE__, :InterconnectorLossGaps)
    include(joinpath(@__DIR__, "..", "..", "scripts", "interconnector_loss_gaps.jl"))
end

@testset "interconnector loss gaps CLI on a saved replay" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 10)
    folder = mktempdir()
    result = replicate_range(db, t1, t2; output_dir = folder)
    @test nrow(result.chunks) == 1

    csv = joinpath(mktempdir(), "loss_gaps.csv")
    main_table = InterconnectorLossGaps.main(
        [
            "--results", folder, "--start", string(t1), "--stop", string(t2),
            "--hive", AEM_TEST_REPLAY_HIVE_DIR, "--output", csv,
        ]
    )
    @test !isempty(main_table) && Set(main_table.DateTime) == Set([t1, t2])
    lines = readlines(csv)
    @test lines[1] == join(names(main_table), ",")
    fields = [split(line, ',') for line in lines[2:end]]
    @test length(fields) == nrow(main_table)
    @test all(length(f) == 7 for f in fields)
    @test Set(parse(DateTime, f[2]) for f in fields) == Set([t1, t2])
    gaps = parse.(Float64, (f[6] for f in fields))
    @test all(isfinite, gaps) && all(<(1.0e-3), abs.(gaps))

    @test_throws ArgumentError InterconnectorLossGaps.main(["--results", folder, "--start", string(t1)])
    @test_throws ArgumentError InterconnectorLossGaps.main(["--results", folder, "--start", string(t1), "--stop", string(t2), "--bogus", "x"])
    @test_throws ArgumentError InterconnectorLossGaps.main(["--results", mktempdir(), "--start", string(t1), "--stop", string(t2), "--hive", AEM_TEST_REPLAY_HIVE_DIR])
end
