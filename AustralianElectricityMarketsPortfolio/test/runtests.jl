using AustralianElectricityMarketsPortfolio
using AustralianElectricityMarketsData
using DuckDB
using PowerSystemsInvestmentsPortfolios
using Test

include("isp_source_fixture.jl")
include(joinpath(@__DIR__, "..", "..", "test", "fixtures", "isp2026_fixture.jl"))

# Test groups, in run order: name => (testset title, files). Pass group names as test arguments
# to run only those, e.g. `Pkg.test(; test_args = ["isp_portfolio_source"])`.
const TEST_GROUPS = [
    "pinned_dependencies" => ("Pinned dependencies", ["pinned_dependencies.jl"]),
    "isp_portfolio_source" => ("ISP source layer", ["isp_source.jl"]),
    "isp_portfolio_properties" => ("ISP property resolution", ["isp_properties.jl"]),
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
