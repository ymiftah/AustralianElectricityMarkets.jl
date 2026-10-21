using AustralianElectricityMarkets
using AustralianElectricityMarketsSimulations
using DataFrames
using Dates
using DuckDB
using PowerSystems
using PowerSimulations
using Test

const AEMS = AustralianElectricityMarketsSimulations
include(joinpath(@__DIR__, "..", "fixtures", "mock_data.jl"))
include(joinpath(@__DIR__, "..", "..", "AustralianElectricityMarketsSimulations", "test", "template_helpers.jl"))
const AEM_TEST_REPLAY_HIVE_DIR = mktempdir()
create_mock_data(AEM_TEST_REPLAY_HIVE_DIR; complete_inputs = true)
write_mock_interconnector_results(AEM_TEST_REPLAY_HIVE_DIR)
include("replay_workflow.jl")
