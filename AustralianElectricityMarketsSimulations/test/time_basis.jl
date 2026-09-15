@testset "DISPATCH_INTERVAL_HOURS" begin
    # 5 minutes / 60 minutes per hour
    @test DISPATCH_INTERVAL_HOURS ≈ 5 / 60
end

@testset "interval_cost_coefficient" begin
    # 300 $/MWh over 5/60 h -> 25 $/MW
    @test interval_cost_coefficient(300.0) ≈ 25.0

    # Market price floor: -1000 $/MWh over 5/60 h -> -1000 * 5 / 60 $/MW
    @test interval_cost_coefficient(-1000.0) ≈ -1000 * 5 / 60

    # Zero price gives a zero coefficient.
    @test interval_cost_coefficient(0.0) ≈ 0.0

    # Int input, 60 $/MWh over 5/60 h -> 5.0 $/MW
    @test interval_cost_coefficient(60) ≈ 5.0
end
