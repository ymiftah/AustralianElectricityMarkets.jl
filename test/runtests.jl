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

include("integration/pscb_fixture.jl")
include("integration/pscb_nemweb_data.jl")
const AEM_TEST_PSCB_HIVE_DIR = mktempdir()
create_pscb_nemweb_data(AEM_TEST_PSCB_HIVE_DIR)

@testset "Data reader tests" begin
    include("datareader.jl")
end

@testset "Network models" begin
    include("network_models/common.jl")
    include("network_models/regional_network_configuration.jl")
    include("network_models/constrained_network_configuration.jl")
end

@testset "Time series setter tests" begin
    include("timeseries_setters.jl")
end

@testset "FCAS types" begin
    include("fcas/fcas.jl")
end

@testset "Constraint types" begin
    include("constraints/constraints.jl")
end

@testset "Interconnector losses" begin
    include("interconnector_losses.jl")
end

@testset "PSCB fixture" begin
    include("integration/pscb_fixture_tests.jl")
end

@testset "PSCB constraints and FCAS" begin
    include("integration/pscb_constraints.jl")
end

@testset "PSCB FCASService" begin
    include("fcas/fcas_service.jl")
end

@testset "System build coverage and JSON round-trip" begin
    include("integration/system_build_coverage.jl")
end


@testset "Aqua" begin
    include("aqua.jl")
end

# TODO Review Jet
# @testset "JET" begin
#     JET.test_package(AustralianElectricityMarkets; target_defined_modules = true)
# end
