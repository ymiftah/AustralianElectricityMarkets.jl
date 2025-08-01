using TidierDB


"""
    read_hive(table_name::Symbol, db::TidierDB.DBInterface.Connection; config::PyHiveConfiguration=CONFIG[])

Read a hive-partitioned parquet dataset into a TidierDB table.

# Arguments
- `table_name::Symbol`: The name of the table to read.
- `db::TidierDB.DBInterface.Connection`: The database connection to use.
- `config::PyHiveConfiguration`: The configuration to use. Defaults to `CONFIG[]`.
"""
function read_hive(
    table_name::Symbol,
    db::TidierDB.DBInterface.Connection;
    config::PyHiveConfiguration=CONFIG[]
)
    hive_root = _parse_hive_root(config)
    hive_path = """
    read_parquet(
        "$hive_root/$table_name/**/*.parquet",
        hive_partitioning=true
    )
    """
    return TidierDB.dt(db, hive_path)
end

function _parse_hive_root(config::PyHiveConfiguration)
    hive_location = config.hive_location
    filesystem = config.filesystem
    if filesystem == "local"
        return hive_location
    elseif filesystem == "gs"
        return "gs://" * hive_location
    end
    throw("Not a known filesystem")
end
