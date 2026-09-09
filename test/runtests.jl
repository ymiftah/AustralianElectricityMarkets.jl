using AustralianElectricityMarkets
using Test
# using JET

using Dates
using DuckDB
using Chain
using DataFrames: nrow
using PowerSystems

include(joinpath(@__DIR__, "..", "AustralianElectricityMarketsData", "test", "mock_data.jl"))
# Create mock data in a temporary directory for the duration of the test session
const AEM_TEST_HIVE_DIR = mktempdir()
create_mock_data(AEM_TEST_HIVE_DIR)

include("pscb_fixture.jl")
include("pscb_nemweb_data.jl")
const AEM_TEST_PSCB_HIVE_DIR = mktempdir()
create_pscb_nemweb_data(AEM_TEST_PSCB_HIVE_DIR)

@testset "Data reader tests" begin
    include("datareader.jl")
end

@testset "Test region model" begin
    include("regionmodel.jl")
end

@testset "Time series setter tests" begin
    include("timeseries_setters.jl")
end

@testset "FCAS types" begin
    include("fcas.jl")
end

@testset "Constraint types" begin
    include("constraints.jl")
end

@testset "PSCB fixture" begin
    include("pscb_fixture_tests.jl")
end

@testset "PSCB constraints and FCAS" begin
    include("pscb_constraints.jl")
end

@testset "PSCB FCASService" begin
    include("fcas_service.jl")
end


@testset "Aqua" begin
    include("aqua.jl")
end

# TODO Review Jet
# @testset "JET" begin
#     JET.test_package(AustralianElectricityMarkets; target_defined_modules = true)
# end
