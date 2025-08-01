using PythonCall
using Dates
using TidierDB

"""
    read_hive(db::TidierDB.DBInterface.Connection,table_name::Symbol; config::PyHiveConfiguration=CONFIG[])

Read a hive-partitioned parquet dataset into a TidierDB table.

# Arguments
- `db::TidierDB.DBInterface.Connection`: The database connection to use.
- `table_name::Symbol`: The name of the table to read.
- `config::PyHiveConfiguration`: The configuration to use. Defaults to `CONFIG[]`.
"""
function read_hive(
    db::TidierDB.DBInterface.Connection,
    table_name::Symbol;
    config::PyHiveConfiguration=CONFIG[],
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

"""
    populate(table::Symbol, time_range::Any; location::String=CONFIG[].hive_location, filesystem=CONFIG[].filesystem)

Download and cache data for a given `table` and `time_range`.

# Arguments
- `table::Symbol`: The table to populate.
- `time_range::Any`: The time range to populate data for. (e.g. `Date(2023,1,1):Date(2023,3,1)`)
- `location::String`: The directory to cache data in. Defaults to `~/.nemweb_cache`.
- `filesystem::String`: The filesystem to use for the cache. Defaults to `local`.
"""
function fetch_table_data(
    table::Symbol,
    time_range::Any;
    location::String=CONFIG[].hive_location,
    filesystem=CONFIG[].filesystem,
)
    dbs = _get_pydb_manager(location, filesystem)
    dbItem = pygetattr(dbs, String(table), nothing)
    if isnothing(dbItem)
        available_tables = list_available_tables()
        throw("No such table exists. Available tables are $available_tables")
    end
    from_date = first(time_range)
    to_date = last(time_range)
    dbItem.populate(pyslice(Py(from_date), Py(to_date)))
end

"""
    list_available_tables()::Array{String}

List the available tables to fetch data for.
"""
function list_available_tables()::Array{Symbol}
    nemdb = pyimport("nemdb")
    config = nemdb.Config
    dbs = nemdb.NEMWEBManager(config)
    return Symbol.(pyconvert(Array, dbs.active_tables()))
end

"""
    _get_pydb_manager(location::String, filesystem::String)

Get a python `nemdb.NEMWEBManager` object.

# Arguments
- `location::String`: The directory to cache data in.
- `filesystem::String`: The filesystem to use for the cache.
"""
function _get_pydb_manager(location::String, filesystem::String)
    nemdb = pyimport("nemdb")
    config = nemdb.Config
    config.set_cache_dir(location)
    config.set_filesystem(filesystem)
    return nemdb.NEMWEBManager(config)
end
