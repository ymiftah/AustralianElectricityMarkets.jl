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

    @testset "Preprocessing" begin
        include("preprocessing.jl")
    end

    @testset "NEM constraints as a PSI Service" begin
        include("nem_constraints.jl")
    end

    @testset "NEM FCAS market participation as a PSI Service" begin
        include("fcas_market.jl")
    end

    @testset "FCAS terms in generic constraints, and price attribution" begin
        include("fcas_pricing.jl")
    end
end
