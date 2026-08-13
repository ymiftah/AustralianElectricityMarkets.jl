"""
    AEMDB(db::DuckDB, config::HiveConfiguration)

    Thin wrapper with the connection and a configuration for the data location
"""
@kwdef struct AEMDB
    db::DuckDB.DB
    config::HiveConfiguration = HiveConfiguration()
end

"""
    aem_connect(config::HiveConfiguration = HiveConfiguration())

Open a DuckDB connection wrapped in an `AEMDB`. Loads the `httpfs` extension
when `config` points at a remote filesystem (S3, GS).
"""
function aem_connect(config::HiveConfiguration = HiveConfiguration())
    db = DuckDB.DB()
    if !islocal(config)
        # Two separate calls — see _new_duckdb_connection for why.
        DuckDB.execute(db, "INSTALL httpfs;")
        DuckDB.execute(db, "LOAD httpfs;")
    end
    return AEMDB(; db, config)
end
