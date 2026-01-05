using AustralianElectricityMarkets
using Test
using TestItems

using Dates
using TidierDB
using DataFrames: nrow
using PowerSystems


# @testset "Test region model" begin
#     include("regionmodel.jl")
# end

@testset "Test parsers" begin
    include("parser.jl")
end

@testset "CI test" begin
    # Write your tests here.
    @test true
end
