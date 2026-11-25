"""
    AEMDB(; db, config = HiveConfiguration())

Thin wrapper pairing a DuckDB connection with the configuration of the data location.

# Fields
- `db::DuckDB.DB`: The DuckDB connection.
- `config::HiveConfiguration`: Where the Hive-partitioned cache lives.
"""
@kwdef struct AEMDB
    db::DuckDB.DB
    config::HiveConfiguration = HiveConfiguration()
end
