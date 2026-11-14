"""
    isp_cache_path(config::HiveConfiguration)::String

Return the path of the ISP cache database, `<hive_location>/ISP/2026/isp.duckdb`.

# Arguments
- `config::HiveConfiguration`: cache configuration; must use the local filesystem.

# Returns
- `String`: path of the database file.

# Examples
```julia
isp_cache_path(HiveConfiguration(; hive_location = "/tmp/x"))  # "/tmp/x/ISP/2026/isp.duckdb"
```
"""
function isp_cache_path(config::HiveConfiguration)::String
    islocal(config) || throw(
        ArgumentError(
            "the ISP cache is a local DuckDB file; got filesystem = $(config.filesystem)."
        )
    )
    return joinpath(config.hive_location, "ISP", "2026", "isp.duckdb")
end

"""
    isp_scenario_schema(scenario::Symbol)::String

Validate `scenario` as a DuckDB schema identifier and return its name as a `String`.

Scenario names are interpolated into DDL, so only a leading letter followed by letters,
digits or underscores is accepted.

# Arguments
- `scenario::Symbol`: ISP scenario name, for example `:step_change`.

# Returns
- `String`: the validated scenario name.

# Examples
```julia
isp_scenario_schema(:step_change)  # "step_change"
```
"""
function isp_scenario_schema(scenario::Symbol)::String
    name = String(scenario)
    occursin(r"^[A-Za-z][A-Za-z0-9_]*$", name) ||
        throw(ArgumentError("invalid scenario name $(repr(name)): expected a leading letter then letters, digits or underscores"))
    return name
end
