using AustralianElectricityMarkets
using Test
using TestItems

include("datareader.jl")
include("regionmodel.jl")

@testitem "CI test" begin
    # Write your tests here.
    @test true
end
