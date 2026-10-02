@testset "IntervalInputs assembly" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    t = DateTime(2025, 1, 1, 0, 5, 0)
    inputs = read_interval_inputs(db, t)

    @test inputs.settlement_date == t
    @test inputs.intervention == 0
    @test !isempty(inputs.initial_mw)
    @test !isempty(inputs.demand)
    @test all(v -> v >= 0.0, values(inputs.demand))
    @test haskey(inputs.initial_mw, "BW01")
    # UIGF only covers semi-scheduled units - and it does cover those: the Dict is a view over
    # `read_uigf`'s single-interval method, so an empty result would be a wiring failure, not a
    # fixture with no semi-scheduled units.
    @test !haskey(inputs.uigf, "BW01")
    @test Set(keys(inputs.uigf)) == Set(["BW03", "BW04"])
    # Fixture profiles at 00:05 (interval 1): BW03 = 40 + i, BW04 = 70 - i.
    @test inputs.uigf["BW03"] ≈ 41.0
    @test inputs.uigf["BW04"] ≈ 69.0

    # Fixture interconnector flows at 00:05 (i=1): MWFLOW = 100*k + i for IC1..IC6.
    @test Set(keys(inputs.interconnector_flows)) == Set(["IC$i" for i in 1:6])
    @test inputs.interconnector_flows["IC1"] ≈ 101.0
    @test inputs.interconnector_flows["IC6"] ≈ 601.0
end

@testset "_read_interconnector_flows throws when DISPATCHINTERCONNECTORRES is not cached" begin
    empty_db = aem_connect(HiveConfiguration(hive_location = mktempdir(), filesystem = "file"))
    t = DateTime(2025, 1, 1, 0, 5, 0)
    err = try
        AustralianElectricityMarketsSimulations._read_interconnector_flows(empty_db, t, 0)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("DISPATCHINTERCONNECTORRES", err.msg)
end

@testset "IntervalInputs no longer carries bid data" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    inputs = read_interval_inputs(db, DateTime(2025, 1, 1, 0, 5, 0))
    @test !hasproperty(inputs, :energy_bids)
    @test !hasproperty(inputs, :fcas_bids)
    @test inputs isa IntervalInputs
    @test !isempty(inputs.demand)
end
