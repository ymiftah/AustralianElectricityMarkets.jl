using AustralianElectricityMarketsData
using Test

using Dates
using DuckDB
using DataFrames: nrow, DataFrame

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

@testset "Aqua" begin
    include("aqua.jl")
end
