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

    # Other resolutions: 300 $/MWh over 30 min -> 150 $/MW; over 1 h -> 300 $/MW.
    @test interval_cost_coefficient(300.0, Minute(30)) ≈ 150.0
    @test interval_cost_coefficient(300.0, Hour(1)) ≈ 300.0
    @test interval_cost_coefficient(300.0, DISPATCH_INTERVAL) ≈ interval_cost_coefficient(300.0)
end

@testset "interval_hours" begin
    @test interval_hours(DISPATCH_INTERVAL) ≈ DISPATCH_INTERVAL_HOURS
    @test interval_hours(Minute(30)) ≈ 0.5
    @test interval_hours(Second(90)) ≈ 90 / 3600
end
