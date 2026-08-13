using AustralianElectricityMarkets
using Test
# using JET

using Dates
using DuckDB
using Chain
using DataFrames: nrow
using PowerSystems

include("mock_data.jl")
# Create mock data in a temporary directory for the duration of the test session
const AEM_TEST_HIVE_DIR = mktempdir()
create_mock_data(AEM_TEST_HIVE_DIR)

@testset "Data reader tests" begin
    include("datareader.jl")
end

@testset "NEMWEB download/cache tests" begin
    include("test-nemweb-load.jl")
end

@testset "ISP data tests" begin
    include("isp_data.jl")
end


@testset "Test region model" begin
    include("regionmodel.jl")
end

@testset "Time series setter tests" begin
    include("timeseries_setters.jl")
end


@testset "Aqua" begin
    include("aqua.jl")
end

# TODO Review Jet
# @testset "JET" begin
#     JET.test_package(AustralianElectricityMarkets; target_defined_modules = true)
# end
