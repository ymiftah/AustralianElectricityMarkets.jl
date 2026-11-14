@testset "pinned dependencies load" begin
    @test isdefined(AustralianElectricityMarketsPortfolio, :PowerSystemsInvestmentsPortfolios)
    @test isdefined(PowerSystemsInvestmentsPortfolios, :Portfolio)
end
