using AustralianElectricityMarkets
using Test
# using JET

using Dates
using TidierDB
using DataFrames: nrow
using PowerSystems

include("mock_data.jl")
# Create mock data in a temporary directory for the duration of the test session
const AEM_TEST_HIVE_DIR = mktempdir()
create_mock_data(AEM_TEST_HIVE_DIR)

@testset "Data reader tests" begin
    include("datareader.jl")
end


@testset "Test region model" begin
    include("regionmodel.jl")
end


@testset "Aqua" begin
    include("aqua.jl")
end

# TODO Review Jet
# @testset "JET" begin
#     JET.test_package(AustralianElectricityMarkets; target_defined_modules = true)
# end
