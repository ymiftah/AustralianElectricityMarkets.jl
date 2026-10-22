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
