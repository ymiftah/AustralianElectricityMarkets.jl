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

write_mock_interconnector_results(AEM_TEST_HIVE_DIR)

# A second hive whose invoked constraints and dispatch rows are all complete, for strict replay.
const AEM_TEST_REPLAY_HIVE_DIR = mktempdir()
create_mock_data(AEM_TEST_REPLAY_HIVE_DIR; complete_inputs = true)
write_mock_interconnector_results(AEM_TEST_REPLAY_HIVE_DIR)

# Test groups, in run order: name => (testset title, file). Pass group names as arguments to run
# only those, e.g. `julia --project=test test/runtests.jl fcas_market pipeline`.
const TEST_GROUPS = [
    "time_basis" => ("Time basis", "time_basis.jl"),
    "tie_break_service" => ("Energy tie-break service", "tie_break_service.jl"),
    "psi_compat" => ("PSI compat", "psi_compat.jl"),
    "nem_constraints" => ("NEM constraints", "nem_constraints.jl"),
    "nem_dispatch" => ("NEM dispatch formulation", "nem_dispatch.jl"),
    "nem_dispatch_toy" => ("NEM dispatch on a toy PSCB system", "nem_dispatch_toy.jl"),
    "fcas_preprocessing" => ("FCAS preprocessing", "fcas_preprocessing.jl"),
    "fcas_market" => ("FCAS market", "fcas_market.jl"),
    "interconnector_losses" => ("Interconnector losses", "interconnector_losses.jl"),
    "replay_validation" => ("Replay validation regressions", "replay_validation.jl"),
    "replication_inputs" => ("Required replay inputs", "replication_inputs.jl"),
    "storage_availability" => ("Elastic storage availability", "storage_availability.jl"),
    "energy_offer_violations" => ("Elastic energy offer totals", "energy_offer_violations.jl"),
    "energy_limits" => ("Elastic energy limits", "energy_limits.jl"),
    "pipeline" => ("Replication pipeline", "pipeline.jl"),
    "recurrent_objective_cache" => ("Recurrent objective forecast cache", "recurrent_objective_cache.jl"),
    "stock_simulation" => ("Stock simulation replay", "stock_simulation.jl"),
    "replay_scripts" => ("Repository replay workflow", "../../test/scripts/replay_workflow.jl"),
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
