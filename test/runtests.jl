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

# Test groups, in run order: name => (testset title, files). Pass group names as test arguments
# to run only those, e.g. `Pkg.test(; test_args = ["fcas", "timeseries_setters"])`.
const TEST_GROUPS = [
    "datareader" => ("Data reader tests", ["datareader.jl"]),
    "network_models" => (
        "Network models",
        [
            "network_models/common.jl",
            "network_models/regional_network_configuration.jl",
            "network_models/constrained_network_configuration.jl",
        ],
    ),
    "timeseries_setters" => ("Time series setter tests", ["timeseries_setters.jl"]),
    "interval_inputs" => ("Per-interval inputs", ["interval_inputs.jl"]),
    "mnsp" => ("MNSP offers", ["mnsp_offers.jl"]),
    "fcas" => ("FCAS types", ["fcas/fcas.jl"]),
    "fcas_scaling" => ("FCAS trapezium scaling", ["fcas/scaling.jl"]),
    "constraints" => ("Constraint types", ["constraints/constraints.jl"]),
    "interconnector_losses" => ("Interconnector losses", ["interconnector_losses.jl"]),
    "pscb_fixture" => ("PSCB fixture", ["integration/pscb_fixture_tests.jl"]),
    "pscb_constraints" => ("PSCB constraints and FCAS", ["integration/pscb_constraints.jl"]),
    "fcas_service" => ("PSCB FCASService", ["fcas/fcas_service.jl"]),
    "system_build_coverage" => ("System build coverage and JSON round-trip", ["integration/system_build_coverage.jl"]),
    "aqua" => ("Aqua", ["aqua.jl"]),
]

const SELECTED_GROUPS = let known = first.(TEST_GROUPS)
    unknown = setdiff(ARGS, known)
    isempty(unknown) || error("Unknown test group(s) $(unknown); choose from $(known).")
    isempty(ARGS) ? known : ARGS
end

for (name, (title, files)) in TEST_GROUPS
    name in SELECTED_GROUPS || continue
    @testset "$title" begin
        foreach(include, files)
    end
end

# TODO Review Jet
# @testset "JET" begin
#     JET.test_package(AustralianElectricityMarkets; target_defined_modules = true)
# end
