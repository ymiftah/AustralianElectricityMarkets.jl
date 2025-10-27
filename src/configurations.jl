using Base.ScopedValues

"""
    HiveConfiguration

Configuration for accessing data.

# Fields
- `hive_location::String`: The directory where data is cached. Defaults to `~/.nemweb_cache`.
- `filesystem::String`: The filesystem to use for the cache. Defaults to `"local"`. See the nemdb documentation for other options.
"""
@kwdef struct HiveConfiguration
    hive_location::String = joinpath(homedir(), ".nemweb_cache")
    filesystem::String = "local"
end

const CONFIG = ScopedValue(HiveConfiguration())
