"""
    NEMBuildReport(; skipped_constraints = Dict{String, Any}[], missing_constraint_intervals = DateTime[],
        defaulted_constraint_weights = String[], dropped_terms = Dict{String, Any}[],
        unavailable_constraints = Dict{String, Any}[])

What [`nem_system`](@ref) left out of, or defaulted in, the constraints it built into a `System`, and which
built constraints the replay inputs made unavailable.

# Fields
- `skipped_constraints`: one row per invoked constraint version that was not built, with `constraint`,
  `reason` and `missing` (the unresolved keys).
- `missing_constraint_intervals`: the dispatch intervals with no invoked constraint.
- `defaulted_constraint_weights`: the versioned names built with the default `constraint_weight`.
- `dropped_terms`: one row per unit term dropped from a built constraint, with `constraint`, `kind`,
  `key`, `bid_type` and `factor`.
- `unavailable_constraints`: one row per built constraint set unavailable by the replay inputs, with
  `constraint` and `reason` (`"never_invoked"` or `"no_available_device"`).
"""
struct NEMBuildReport
    skipped_constraints::Vector{Dict{String, Any}}
    missing_constraint_intervals::Vector{DateTime}
    defaulted_constraint_weights::Vector{String}
    dropped_terms::Vector{Dict{String, Any}}
    unavailable_constraints::Vector{Dict{String, Any}}
end

function NEMBuildReport(;
        skipped_constraints = Dict{String, Any}[],
        missing_constraint_intervals = DateTime[],
        defaulted_constraint_weights = String[],
        dropped_terms = Dict{String, Any}[],
        unavailable_constraints = Dict{String, Any}[],
    )
    return NEMBuildReport(
        Dict{String, Any}[Dict{String, Any}(r) for r in skipped_constraints],
        DateTime[t for t in missing_constraint_intervals],
        String[w for w in defaulted_constraint_weights],
        Dict{String, Any}[Dict{String, Any}(r) for r in dropped_terms],
        Dict{String, Any}[Dict{String, Any}(r) for r in unavailable_constraints],
    )
end

function Base.:(==)(a::NEMBuildReport, b::NEMBuildReport)
    return all(f -> getfield(a, f) == getfield(b, f), fieldnames(NEMBuildReport))
end

function Base.hash(report::NEMBuildReport, h::UInt)
    return hash(Tuple(getfield(report, f) for f in fieldnames(NEMBuildReport)), h)
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
        "skipped_constraints" => deepcopy(report.skipped_constraints),
        "missing_constraint_intervals" => string.(report.missing_constraint_intervals),
        "defaulted_constraint_weights" => copy(report.defaulted_constraint_weights),
        "dropped_terms" => deepcopy(report.dropped_terms),
        "unavailable_constraints" => deepcopy(report.unavailable_constraints),
    )
    return report
end


"""
    get_build_report(sys) -> NEMBuildReport

The [`NEMBuildReport`](@ref) stored on `sys` by [`set_build_report!`](@ref).

# Arguments
- `sys`: a `System` built by `nem_system`.

# Returns
The stored report, or an empty `NEMBuildReport` when none was stored (no constraints were built into `sys`).
"""
function get_build_report(sys)
    data = get(get_ext(sys), "build_report", nothing)
    isnothing(data) && return NEMBuildReport()
    return NEMBuildReport(;
        skipped_constraints = data["skipped_constraints"],
        missing_constraint_intervals = DateTime[DateTime(String(t)) for t in data["missing_constraint_intervals"]],
        defaulted_constraint_weights = collect(String, data["defaulted_constraint_weights"]),
        dropped_terms = data["dropped_terms"],
        unavailable_constraints = data["unavailable_constraints"],
    )
end
