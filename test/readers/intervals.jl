@testset "Published outcome readers" begin
    inputs_hive = joinpath(mktempdir(), "hive")
    cp(AEM_TEST_HIVE_DIR, inputs_hive)
    write_mock_interconnector_results(inputs_hive)
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
