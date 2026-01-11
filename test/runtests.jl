using AustralianElectricityMarkets
using Test
using TestItemRunner
using JET

using Dates
using TidierDB
using DataFrames: nrow
using PowerSystems

@testset "Aqua" begin
    include("aqua.jl")
end

# Review Jet
# @testset "JET" begin
#     JET.test_package(AustralianElectricityMarkets; target_defined_modules = true)
# end

@testset "Test region model" begin
    include("regionmodel.jl")
end

@run_package_tests verbose = true
