using AustralianElectricityMarketsPortfolio
using PowerSystemsInvestmentsPortfolios
using Test

@testset "AustralianElectricityMarketsPortfolio" begin
    @testset "pinned dependencies load" begin
        @test isdefined(AustralianElectricityMarketsPortfolio, :PowerSystemsInvestmentsPortfolios)
        @test isdefined(PowerSystemsInvestmentsPortfolios, :Portfolio)
    end
    include("aqua.jl")
end
