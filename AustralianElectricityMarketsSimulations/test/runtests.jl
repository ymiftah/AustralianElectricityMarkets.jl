using AustralianElectricityMarketsSimulations
using AustralianElectricityMarkets
using AustralianElectricityMarketsData
using DataFrames
using Dates
using PowerSystems
using Test

include(joinpath(@__DIR__, "..", "..", "AustralianElectricityMarketsData", "test", "mock_data.jl"))

const AEM_TEST_HIVE_DIR = mktempdir()
create_mock_data(AEM_TEST_HIVE_DIR)

@testset "AustralianElectricityMarketsSimulations" begin
    @testset "Interval inputs" begin
        include("inputs.jl")
    end
end
