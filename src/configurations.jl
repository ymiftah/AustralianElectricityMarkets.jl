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

abstract type NetworkConfiguration end

function table_requirements(::NetworkConfiguration)
    error("Not implemented")
end
