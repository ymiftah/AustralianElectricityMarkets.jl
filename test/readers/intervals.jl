@testset "Interval and published outcome readers" begin
    inputs_hive = joinpath(mktempdir(), "hive")
    cp(AEM_TEST_HIVE_DIR, inputs_hive)
    write_mock_interconnector_results(inputs_hive)
    @testset "IntervalInputs assembly" begin
        db = aem_connect(HiveConfiguration(hive_location = inputs_hive, filesystem = "file"))
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
            AustralianElectricityMarkets.Readers._read_interconnector_flows(empty_db, t, 0)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("DISPATCHINTERCONNECTORRES", err.msg)
    end

    @testset "IntervalInputs no longer carries bid data" begin
        db = aem_connect(HiveConfiguration(hive_location = inputs_hive, filesystem = "file"))
        inputs = read_interval_inputs(db, DateTime(2025, 1, 1, 0, 5, 0))
        @test !hasproperty(inputs, :energy_bids)
        @test !hasproperty(inputs, :fcas_bids)
        @test inputs isa IntervalInputs
        @test !isempty(inputs.demand)
    end

    db = aem_connect(HiveConfiguration(hive_location = inputs_hive))
    t = DateTime(2025, 1, 1, 0, 5)
    @testset "published interval" begin
        published = read_published_interval(db, t)
        # Mock flows at 00:05 (i = 1): MWFLOW = 100 * k + i for IC1..IC6.
        flows = Dict(zip(published.interconnectors.INTERCONNECTORID, published.interconnectors.MWFLOW))
        @test flows == Dict("IC$k" => 100.0k + 1 for k in 1:6)
        @test "BW01" in published.dispatch.DUID
        @test eltype(published.dispatch.TOTALCLEARED) <: Union{Missing, Float64}
        @test !isempty(published.prices)
        @test all(==(t), published.fcas_prices.SETTLEMENTDATE)

        # The mock carries only the pricing run (and no INTERVENTION column on interconnector results).
        physical = read_published_interval(db, t; intervention = 1)
        @test all(isempty, (physical.dispatch, physical.prices, physical.fcas_prices))
    end

end
