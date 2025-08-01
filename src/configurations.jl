using Base.ScopedValues

"""
    PyHiveConfiguration

Configuration for accessing data.

# Fields
- `hive_location::String`: The directory where data is cached. Defaults to `~/.nemweb_cache`.
- `filesystem::String`: The filesystem to use for the cache. Defaults to `"local"`. See the nemdb documentation for other options.
"""
@kwdef struct PyHiveConfiguration
    hive_location::String = joinpath(homedir(), ".nemweb_cache")
    filesystem::String = "local"
end

const CONFIG = ScopedValue(PyHiveConfiguration())
