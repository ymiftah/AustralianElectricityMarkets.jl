module AustralianElectricityMarketsData

using PythonCall

export HiveConfiguration, fetch_table_data, list_available_tables

@kwdef struct HiveConfiguration
    base_dir::String = joinpath(homedir(), ".nemweb_cache")
    filesystem::String = "local"
end

function default_hive_config()
    return HiveConfiguration()
end


"""
    fetch_table_data(table::Symbol, time_range::Any; location::String=CONFIG[].hive_location, filesystem=CONFIG[].filesystem)

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
        hive_configuration::HiveConfiguration = default_hive_config(),
    )
    dbs = _get_pydb_manager(hive_configuration)
    dbItem = pygetattr(dbs, String(table), nothing)
    if isnothing(dbItem)
        available_tables = list_available_tables()
        throw("No such table exists. Available tables are $available_tables")
    end
    from_date = first(time_range)
    to_date = last(time_range)
    return dbItem.populate(pyslice(Py(from_date), Py(to_date)))
end

"""
    fetch_table_data(table::Symbol, time_range::Any; location::String=CONFIG[].hive_location, filesystem=CONFIG[].filesystem)

Download and cache data for a given `table` and `time_range`.

# Arguments
- `table::Symbol`: The table to populate.
- `time_range::Any`: The time range to populate data for. (e.g. `Date(2023,1,1):Date(2023,3,1)`)
- `location::String`: The directory to cache data in. Defaults to `~/.nemweb_cache`.
- `filesystem::String`: The filesystem to use for the cache. Defaults to `local`.
"""
function fetch_table_data(
        time_range::Any;
        hive_configuration::HiveConfiguration = default_hive_config(),
    )
    dbs = _get_pydb_manager(hive_configuration)
    from_date = first(time_range)
    to_date = last(time_range)
    return dbs.populate(pyslice(Py(from_date), Py(to_date)))
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
- `hive_configuration::HiveConfiguration`: The configuration
"""
function _get_pydb_manager(hive_configuration::HiveConfiguration)
    nemdb = pyimport("nemdb")
    config = nemdb.Config
    config.set_cache_dir(hive_configuration.base_dir)
    config.set_filesystem(hive_configuration.filesystem)
    return nemdb.NEMWEBManager(config)
end

end
