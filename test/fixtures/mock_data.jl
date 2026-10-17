using DataFrames
using Dates
using DuckDB

# The generator lives in the root package source so the Simulations precompile workload can use it.
include(joinpath(@__DIR__, "..", "..", "src", "mock_hive.jl"))

"""
    create_mock_data(hive_root)

Writes the mock NEMWEB hive of [`_write_mock_hive`](@ref) under `hive_root`.
"""
create_mock_data(hive_root::String) = _write_mock_hive(hive_root)

"""
    create_versioned_static_data(src_dir, dst_dir)

Copies the mock hive at `src_dir` to `dst_dir`, then adds a version effective 2025-07-01 to
`INTERCONNECTORCONSTRAINT` (IC1: `MAXMWIN` 300 instead of 500) and `DUDETAILSUMMARY` (BW01:
`CONNECTIONPOINTID` `CP_NEW` instead of `CP_BAYSW`, closing the old row at that date), so that
"latest" and "as of 2025-03-01" resolve differently. Each of the three tables also gets an
older `2024-12` archive holding a stale, still-open version that the latest archive supersedes,
so a read that does not restrict to the latest archive resolves it wrongly.
"""
function create_versioned_static_data(src_dir::String, dst_dir::String)
    cp(src_dir, dst_dir; force = true)
    ddb = DuckDB.DB()
    conn = DuckDB.connect(ddb)
    DuckDB.execute(conn, "SET preserve_identifier_case=true")
    function rewrite(f, table)
        table_dir = joinpath(dst_dir, table)
        df = DataFrame(DuckDB.execute(conn, "SELECT * FROM read_parquet('$table_dir/**/*.parquet', hive_partitioning=true)"))
        df = f(df)
        rm(table_dir; recursive = true)
        mkpath(table_dir)
        DuckDB.register_data_frame(conn, df, "tmp_table")
        DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
        return DuckDB.unregister_table(conn, "tmp_table")
    end
    effective = DateTime(2025, 7, 1)
    rewrite("INTERCONNECTORCONSTRAINT") do df
        new = df[df.INTERCONNECTORID .== "IC1", :]
        new = copy(new)
        new.EFFECTIVEDATE .= effective
        new.MAXMWIN .= 300.0
        stale = copy(new)
        stale.EFFECTIVEDATE .= DateTime(2025, 2, 1)
        stale.VERSIONNO .= 9
        stale.MAXMWIN .= 111.0
        stale.archive_month .= "2024-12"
        return vcat(df, new, stale)
    end
    rewrite("DUDETAILSUMMARY") do df
        df = copy(df)
        df.END_DATE = Union{DateTime, Missing}[x for x in df.END_DATE]
        old = df.DUID .== "BW01"
        new = df[old, :]
        new = copy(new)
        df.END_DATE[old] .= effective
        new.START_DATE .= effective
        new.CONNECTIONPOINTID .= "CP_NEW"
        stale = copy(df[old, :])
        stale.START_DATE .= DateTime(2021, 1, 1)
        stale.END_DATE .= missing
        stale.CONNECTIONPOINTID .= "CP_STALE"
        stale.archive_month .= "2024-12"
        return vcat(df, new, stale)
    end
    rewrite("DUDETAIL") do df
        stale = copy(df[df.DUID .== "BW01", :])
        stale.EFFECTIVEDATE .= DateTime(2025, 2, 1)
        stale.VERSIONNO .= 9
        stale.REGISTEREDCAPACITY .= 1.0
        stale.archive_month .= "2024-12"
        return vcat(df, stale)
    end
    return DuckDB.disconnect(conn)
end
