using AustralianElectricityMarketsSimulations
using AustralianElectricityMarkets
using DataFrames
using Dates
using DuckDB
using PowerSystems
using Test

const AEMS = AustralianElectricityMarketsSimulations

include(joinpath(@__DIR__, "..", "..", "test", "fixtures", "mock_data.jl"))
include(joinpath(@__DIR__, "..", "..", "test", "integration", "pscb_fixture.jl"))
include(joinpath(@__DIR__, "..", "..", "test", "integration", "pscb_nemweb_data.jl"))
include(joinpath(@__DIR__, "template_helpers.jl"))
include(joinpath(@__DIR__, "toy_fixture.jl"))

const AEM_TEST_HIVE_DIR = mktempdir()
create_mock_data(AEM_TEST_HIVE_DIR)

# Add interconnector results needed by the interval readers to the shared fixture.
_write_mock_interconnector_results(AEM_TEST_HIVE_DIR)

# Test groups, in run order: name => (testset title, file). Pass group names as arguments to run
# only those, e.g. `julia --project=test test/runtests.jl fcas_market preprocessing`.
const TEST_GROUPS = [
    "time_basis" => ("Time basis", "time_basis.jl"),
    "inputs" => ("Interval inputs", "inputs.jl"),
    "preprocessing" => ("Preprocessing", "preprocessing.jl"),
    "constraint_formulations" => ("Constraint formulations", "constraint_formulations.jl"),
    "psi_compat" => ("PSI compat", "psi_compat.jl"),
    "nem_constraints" => ("NEM constraints", "nem_constraints.jl"),
    "nem_dispatch" => ("NEM dispatch formulation", "nem_dispatch.jl"),
    "nem_dispatch_toy" => ("NEM dispatch on a toy PSCB system", "nem_dispatch_toy.jl"),
    "fcas_market" => ("FCAS market", "fcas_market.jl"),
    "fcas_preprocessing" => ("FCAS preprocessing", "fcas_preprocessing.jl"),
    "interconnector_losses" => ("Interconnector losses", "interconnector_losses.jl"),
    "pipeline" => ("Replication pipeline", "pipeline.jl"),
    "stock_simulation" => ("Stock simulation replay", "stock_simulation.jl"),
]

const SELECTED_GROUPS = let known = first.(TEST_GROUPS)
    unknown = setdiff(ARGS, known)
    isempty(unknown) || error("Unknown test group(s) $(unknown); choose from $(known).")
    isempty(ARGS) ? known : ARGS
end

@testset "AustralianElectricityMarketsSimulations" begin
    for (name, (title, file)) in TEST_GROUPS
        name in SELECTED_GROUPS || continue
        @testset "$title" begin
            include(file)
        end
    end
end
