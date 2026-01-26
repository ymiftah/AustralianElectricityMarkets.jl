using AustralianElectricityMarkets
using Test
using TestItemRunner
# using JET

using Dates
using TidierDB
using DataFrames: nrow
using PowerSystems

include("mock_data.jl")
# Create mock data in a temporary directory for the duration of the test session
tmpdir = mktempdir()
create_mock_data(tmpdir)
ENV["AEM_TEST_HIVE_DIR"] = tmpdir

@run_package_tests verbose = true

@testset "Aqua" begin
    include("aqua.jl")
end

# TODO Review Jet
# @testset "JET" begin
#     JET.test_package(AustralianElectricityMarkets; target_defined_modules = true)
# end

@testset "Test region model" begin
    include("regionmodel.jl")
end
