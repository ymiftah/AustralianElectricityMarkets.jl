"""
    aem_connect(config::HiveConfiguration = HiveConfiguration())

Open a DuckDB connection wrapped in an `AEMDB`. Loads the `httpfs` extension
when `config` points at a remote filesystem (S3, GS).
"""
function aem_connect(config::HiveConfiguration = HiveConfiguration())
    db = DuckDB.DB()
    if !islocal(config)
        DuckDB.execute(db, "INSTALL httpfs;")
        DuckDB.execute(db, "LOAD httpfs;")
    end
    return AEMDB(; db, config)
end

"""
    _local_tmp_dir() -> String

Shared scratch directory, under the system tempdir, for DuckDB's spill files
and the pipeline's own downloaded/extracted files.
"""
function _local_tmp_dir()
    dir = joinpath(tempdir(), "aem_nemweb")
    mkpath(dir)
    return dir
end


"""
    _new_duckdb_connection(filesystem::String = "file") -> DuckDB.DB

Open a DuckDB connection configured to spill to disk once memory use crosses
a conservative bound, rather than growing unbounded. Loads the `httpfs`
extension when `filesystem` is remote (`"s3"`/`"gs"`), so subsequent
`COPY`/`glob()` calls can reach it.
"""
function _new_duckdb_connection(filesystem::String = "file")
    conn = DuckDB.DB()
    if !islocal(filesystem)
        # Two separate calls, not one "INSTALL httpfs; LOAD httpfs;" string —
        # DuckDB.jl 1.5.2 raises "Cannot prepare multiple statements at once!"
        # on a semicolon-joined multi-statement string (confirmed directly).
        DuckDB.execute(conn, "INSTALL httpfs;")
        DuckDB.execute(conn, "LOAD httpfs;")
    end
    DBInterface.execute(conn, "SET memory_limit='4GB'")
    DBInterface.execute(conn, "SET temp_directory='$(_local_tmp_dir())'")
    return conn
end
