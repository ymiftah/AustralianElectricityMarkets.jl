@testset "interval_hours" begin
    @test interval_hours(DISPATCH_INTERVAL) ≈ 5 / 60
end

@testset "interval_cost_coefficient" begin
    # 300 $/MWh over 5/60 h -> 25 $/MW; over 30 min -> 150 $/MW.
    @test interval_cost_coefficient(300.0) ≈ 25.0
    @test interval_cost_coefficient(300.0, Minute(30)) ≈ 150.0
end
