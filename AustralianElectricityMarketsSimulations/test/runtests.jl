using AustralianElectricityMarketsSimulations
using AustralianElectricityMarkets
using AustralianElectricityMarketsData
using DataFrames
using Dates
using DuckDB
using PowerSystems
using Test

include(joinpath(@__DIR__, "..", "..", "AustralianElectricityMarketsData", "test", "mock_data.jl"))

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

@testset "AustralianElectricityMarketsSimulations" begin
    @testset "Interval inputs" begin
        include("inputs.jl")
    end

    @testset "Preprocessing" begin
        include("preprocessing.jl")
    end

    @testset "NEM constraints as a PSI Service" begin
        include("nem_constraints.jl")
    end

    @testset "NEM FCAS market participation as a PSI Service" begin
        include("fcas_market.jl")
    end

    @testset "FCAS terms in generic constraints, and price attribution" begin
        include("fcas_pricing.jl")
    end

    @testset "NEMInterconnectorLoss: interconnector losses on AreaInterchange" begin
        include("interconnector_losses.jl")
    end
end
