using AustralianElectricityMarketsSimulations
using AustralianElectricityMarkets
using AustralianElectricityMarketsData
using DataFrames
using Dates
using DuckDB
using PowerSystems
using Test

const AEMS = AustralianElectricityMarketsSimulations

include(joinpath(@__DIR__, "..", "..", "AustralianElectricityMarketsData", "test", "mock_data.jl"))
include(joinpath(@__DIR__, "..", "..", "test", "integration", "pscb_fixture.jl"))
include(joinpath(@__DIR__, "..", "..", "test", "integration", "pscb_nemweb_data.jl"))
include(joinpath(@__DIR__, "template_helpers.jl"))
include(joinpath(@__DIR__, "toy_fixture.jl"))

const AEM_TEST_HIVE_DIR = mktempdir()
create_mock_data(AEM_TEST_HIVE_DIR)

# mock_data.jl (shared with the root/Data test suites, not modified here - see this repo's
# task notes) never wrote DISPATCHINTERCONNECTORRES. Add it directly so
# `_read_interconnector_flows` (used by `read_interval_inputs`) has data to read, now that a
# missing table is a hard error rather than a silently empty Dict.
let
    ddb = DuckDB.DB()
    conn = DuckDB.connect(ddb)
    DuckDB.execute(conn, "SET preserve_identifier_case=true")
    interconnector_ids = ["IC$i" for i in 1:6]
    base_datetime = DateTime(2025, 1, 1, 0, 0)
    df = DataFrame()
    for i in 0:48
        t = base_datetime + Minute(5 * i)
        append!(
            df, DataFrame(
                SETTLEMENTDATE = fill(t, length(interconnector_ids)),
                INTERCONNECTORID = interconnector_ids,
                MWFLOW = [100.0 * k + i for k in 1:length(interconnector_ids)],
                MWLOSSES = [0.1 * k for k in 1:length(interconnector_ids)],
                METEREDMWFLOW = [100.0 * k + i for k in 1:length(interconnector_ids)],
                # Equal to the mock's static 500 MW limits, so they do not tighten any flow.
                EXPORTLIMIT = fill(500.0, length(interconnector_ids)),
                IMPORTLIMIT = fill(-500.0, length(interconnector_ids)),
                archive_month = fill("2025-01", length(interconnector_ids)),
            )
        )
    end
    DuckDB.register_data_frame(conn, df, "tmp_table")
    table_dir = joinpath(AEM_TEST_HIVE_DIR, "DISPATCHINTERCONNECTORRES")
    mkpath(table_dir)
    DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
    DuckDB.unregister_table(conn, "tmp_table")
end

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
    "interconnector_losses" => ("Interconnector losses", "interconnector_losses.jl"),
    "pipeline" => ("Replication pipeline", "pipeline.jl"),
    "validation" => ("Validation harness", "validation.jl"),
    "compare_dispatch" => ("Dispatch comparison", "compare_dispatch.jl"),
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
