using AustralianElectricityMarketsSimulations
using AustralianElectricityMarkets
using AustralianElectricityMarketsData
using DataFrames
using Dates
using HiGHS
using PowerSystems
using Test

include(joinpath(@__DIR__, "..", "..", "AustralianElectricityMarketsData", "test", "mock_data.jl"))
include(joinpath(@__DIR__, "..", "..", "test", "pscb_fixture.jl"))
include(joinpath(@__DIR__, "..", "..", "test", "pscb_nemweb_data.jl"))

const AEM_TEST_HIVE_DIR = mktempdir()
create_mock_data(AEM_TEST_HIVE_DIR)

@testset "AustralianElectricityMarketsSimulations" begin
    @testset "Interval inputs" begin
        include("inputs.jl")
    end

    @testset "Preprocessing" begin
        include("preprocessing.jl")
    end

    @testset "Fidelity tiers" begin
        include("tiers.jl")
    end

    include("fcas_variables.jl")
end
