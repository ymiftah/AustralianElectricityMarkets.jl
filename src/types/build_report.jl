"""
    NEMBuildReport(; skipped_constraints, missing_constraint_intervals = DateTime[],
        defaulted_constraint_weights = String[], dropped_terms, unavailable_constraints)

What [`nem_system`](@ref) left out of, or defaulted in, the constraints it built into a `System`, and which
built constraints the NEMDE inputs made unavailable. The three table keywords take a `DataFrame` or a vector
of row `Dict`s with the columns below (default: no rows); the report stores its own copy.

# Fields
- `skipped_constraints`: a `DataFrame` with one row per invoked constraint version that was not built, with
  `constraint`, `reason` and `missing` (the unresolved keys).
- `missing_constraint_intervals`: the dispatch intervals with no invoked constraint.
- `defaulted_constraint_weights`: the versioned names built with the default `constraint_weight`.
- `dropped_terms`: a `DataFrame` with one row per unit term dropped from a built constraint, with `constraint`,
  `kind`, `key`, `bid_type`, `factor` and `registered` (the unit is registered at some interval of the build
  range; `true` when not given).
- `unavailable_constraints`: a `DataFrame` with one row per built constraint set unavailable by the NEMDE
  inputs, with `constraint` and `reason` (`"never_invoked"` or `"no_available_device"`).
"""
struct NEMBuildReport
    skipped_constraints::DataFrame
    missing_constraint_intervals::Vector{DateTime}
    defaulted_constraint_weights::Vector{String}
    dropped_terms::DataFrame
    unavailable_constraints::DataFrame
end

# Column names and types of each report table, in storage order.
const _BUILD_REPORT_SCHEMAS = (
    skipped_constraints = (:constraint => String, :reason => String, :missing => Vector{String}),
    dropped_terms = (
        :constraint => String, :kind => String, :key => String, :bid_type => String, :factor => Float64,
        :registered => Bool,
    ),
    unavailable_constraints = (:constraint => String, :reason => String),
)

# A fresh `DataFrame` of `rows` (a `DataFrame` or row `Dict`s) with exactly the columns of `schema`.
function _report_table(rows, schema; defaults = (;))
    columns = map(schema) do (name, type)
        default = get(defaults, name, nothing)
        values = if rows isa AbstractDataFrame
            hasproperty(rows, name) ? rows[!, name] : fill(default, nrow(rows))
        else
            [get(r, String(name), default) for r in rows]
        end
        return name => type[type(v) for v in values]
    end
    return DataFrame(columns...)
end

function NEMBuildReport(;
        skipped_constraints = Dict{String, Any}[],
        missing_constraint_intervals = DateTime[],
        defaulted_constraint_weights = String[],
        dropped_terms = Dict{String, Any}[],
        unavailable_constraints = Dict{String, Any}[],
    )
    schemas = _BUILD_REPORT_SCHEMAS
    return NEMBuildReport(
        _report_table(skipped_constraints, schemas.skipped_constraints),
        DateTime[t for t in missing_constraint_intervals],
        String[w for w in defaulted_constraint_weights],
        _report_table(dropped_terms, schemas.dropped_terms; defaults = (registered = true,)),
        _report_table(unavailable_constraints, schemas.unavailable_constraints),
    )
end

function Base.:(==)(a::NEMBuildReport, b::NEMBuildReport)
    return all(f -> getfield(a, f) == getfield(b, f), fieldnames(NEMBuildReport))
end

function Base.hash(report::NEMBuildReport, h::UInt)
    return hash(Tuple(getfield(report, f) for f in fieldnames(NEMBuildReport)), h)
end


# The columns of `df` as a plain `Dict`, deep-copied so the stored report is independent of `df`.
function _column_dict(df)
    return Dict{String, Any}(String(n) => deepcopy(col) for (n, col) in pairs(eachcol(df)))
end


"""
    set_build_report!(sys, report::NEMBuildReport) -> NEMBuildReport

Stores a copy of `report` on `sys` under one key of its `ext`, as plain data so it survives a `System` JSON
round-trip. Later changes to `report` do not reach `sys`. Repeat calls replace the stored report.

# Arguments
- `sys`: the `System` the report describes.
- `report`: the [`NEMBuildReport`](@ref).

# Returns
`report`.
"""
function set_build_report!(sys, report::NEMBuildReport)
    get_ext(sys)["build_report"] = Dict{String, Any}(
        "skipped_constraints" => _column_dict(report.skipped_constraints),
        "missing_constraint_intervals" => string.(report.missing_constraint_intervals),
        "defaulted_constraint_weights" => copy(report.defaulted_constraint_weights),
        "dropped_terms" => _column_dict(report.dropped_terms),
        "unavailable_constraints" => _column_dict(report.unavailable_constraints),
    )
    return report
end


"""
    get_build_report(sys) -> NEMBuildReport

The [`NEMBuildReport`](@ref) stored on `sys` by [`set_build_report!`](@ref).

# Arguments
- `sys`: a `System` built by `nem_system`.

# Returns
The stored report, or an empty `NEMBuildReport` when none was stored. Throws `ArgumentError` for a
stored report without `unavailable_constraints`.
"""
function get_build_report(sys)
    data = get(get_ext(sys), "build_report", nothing)
    isnothing(data) && return NEMBuildReport()
    haskey(data, "unavailable_constraints") || throw(
        ArgumentError("the build report of the system predates `unavailable_constraints`; rebuild it with nem_system"),
    )
    return NEMBuildReport(;
        skipped_constraints = DataFrame(data["skipped_constraints"]),
        missing_constraint_intervals = DateTime[DateTime(String(t)) for t in data["missing_constraint_intervals"]],
        defaulted_constraint_weights = collect(String, data["defaulted_constraint_weights"]),
        dropped_terms = DataFrame(data["dropped_terms"]),
        unavailable_constraints = DataFrame(data["unavailable_constraints"]),
    )
end
