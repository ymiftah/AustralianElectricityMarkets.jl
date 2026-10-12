"""
    AEMDB(db::DuckDB, config::HiveConfiguration)

    Thin wrapper with the connection and a configuration for the data location
"""
@kwdef struct AEMDB
    db::DuckDB.DB
    config::HiveConfiguration = HiveConfiguration()
end
