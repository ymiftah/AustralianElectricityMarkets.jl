"""
    HiveConfiguration

Configuration for accessing data.

# Fields
- `hive_location::String`: The directory where data is cached. Defaults to `~/.nemdb_cache`.
- `filesystem::String`: The filesystem to use for the cache. Defaults to `"local"`. Can be s3, gs.
"""
@kwdef struct HiveConfiguration
    hive_location::String = joinpath(homedir(), ".nemdb_cache")
    filesystem::String = "file"
end

islocal(filesystem::String) = filesystem == "file"
islocal(config::HiveConfiguration) = islocal(config.filesystem)
get_filesystem(config::HiveConfiguration) = config.filesystem

"""
    get_filesystem(path::String) -> String

Extract the scheme from a resolved Hive-root/data path (e.g. `"s3"` from
`"s3://bucket/..."`), or `"file"` for a plain local path with no scheme.
"""
function get_filesystem(path::String)::String
    parts = split(path, "://"; limit = 2)
    return length(parts) == 2 ? String(parts[1]) : "file"
end

"""
    _parse_hive_root(config::HiveConfiguration)

Construct the correct path to the Hive dataset based on the specified filesystem.

# Arguments
- `config::HiveConfiguration`: The configuration object containing filesystem and location details.
"""
function _parse_hive_root(config::HiveConfiguration)
    if islocal(config)
        return config.hive_location
    else
        prefix = get_filesystem(config)
        return "$(prefix)://" * config.hive_location
    end
end

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
        DuckDB.execute(db, "INSTALL httpfs;")
        DuckDB.execute(db, "LOAD httpfs;")
    end
    return AEMDB(; db, config)
end
