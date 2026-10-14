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
