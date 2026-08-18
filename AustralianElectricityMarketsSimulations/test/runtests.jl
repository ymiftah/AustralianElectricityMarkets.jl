using AustralianElectricityMarketsSimulations
using Test

@testset "AustralianElectricityMarketsSimulations" begin
    @test AustralianElectricityMarketsSimulations isa Module
    @test isdefined(AustralianElectricityMarketsSimulations, :AustralianElectricityMarkets)
end
