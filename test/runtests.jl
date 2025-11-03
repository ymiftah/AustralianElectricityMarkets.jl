using AustralianElectricityMarkets
using Test
using TestItems

import AustralianElectricityMarkets.RegionModel as RM
using Dates
using TidierDB
using DataFrames: nrow
using PowerSystems


@testset "Test region model" begin
    include("regionmodel.jl")
end

@testset "CI test" begin
    # Write your tests here.
    @test true
end
