using AustralianElectricityMarketsData
using Test

using Dates
using DuckDB
using DataFrames: nrow, DataFrame

include(joinpath(@__DIR__, "..", "..", "test", "fixtures", "mock_data.jl"))
# Create mock data in a temporary directory for the duration of the test session
const AEM_TEST_HIVE_DIR = mktempdir()
create_mock_data(AEM_TEST_HIVE_DIR)

@testset "NEMWEB download/cache tests" begin
    include("test-nemweb-load.jl")
end

@testset "Aqua" begin
    include("aqua.jl")
end
