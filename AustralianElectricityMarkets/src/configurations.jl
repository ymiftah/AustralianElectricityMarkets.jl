using Base.ScopedValues

"""
    HiveConfiguration

Configuration for accessing data.

# Fields
- `hive_location::String`: The directory where data is cached. Defaults to `~/.nemweb_cache`.
- `filesystem::String`: The filesystem to use for the cache. Defaults to `"local"`. Can be s3, gs.
"""
@kwdef struct HiveConfiguration
    hive_location::String = joinpath(homedir(), ".aem_cache")
    filesystem::String = "file"
end

islocal(config::HiveConfiguration) = config.filesystem == "file"
get_backend(config::HiveConfiguration) = config.filesystem

const CONFIG = ScopedValue(HiveConfiguration())


abstract type NetworkConfiguration end
