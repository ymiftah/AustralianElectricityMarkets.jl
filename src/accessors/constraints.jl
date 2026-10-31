"""
    get_skipped_constraints(sys) -> DataFrame

The invoked constraint versions [`nem_system`](@ref) did not build into `sys`.

# Arguments
- `sys`: a `System` built by `nem_system`.

# Returns
A `DataFrame` with `constraint` (versioned name), `reason` (`:no_definition`, `:no_terms`,
`:unknown_duid`, `:unknown_region` or `:unknown_interconnector`, the kind of the first
unresolved term), `n_missing` (number of unresolved term keys of any kind) and `missing_keys`
(those keys). Empty when nothing was skipped or no constraints were built into `sys`.
"""
function get_skipped_constraints(sys)
    rows = get(get_ext(sys), "skipped_constraints", Dict{String, Any}[])
    return DataFrame(;
        constraint = String[r["constraint"] for r in rows],
        reason = Symbol[Symbol(r["reason"]) for r in rows],
        n_missing = Int[length(r["missing"]) for r in rows],
        missing_keys = Vector{String}[String[k for k in r["missing"]] for r in rows],
    )
end


"""
    get_dropped_terms(sys) -> DataFrame

The unit terms [`nem_system`](@ref) dropped from built constraints because their DUID is
absent from `sys`.

# Arguments
- `sys`: a `System` built by `nem_system`.

# Returns
A `DataFrame` with `constraint` (versioned name), `kind`, `key`, `bid_type` and `factor`, one row
per dropped term. Empty when nothing was dropped or no constraints were built into `sys`.
"""
function get_dropped_terms(sys)
    rows = get(get_ext(sys), "dropped_terms", Dict{String, Any}[])
    return DataFrame(;
        constraint = String[r["constraint"] for r in rows],
        kind = String[r["kind"] for r in rows],
        key = String[r["key"] for r in rows],
        bid_type = String[r["bid_type"] for r in rows],
        factor = Float64[r["factor"] for r in rows],
    )
end


"""
    get_missing_constraint_intervals(sys) -> Vector{DateTime}

The dispatch intervals of the range [`nem_system`](@ref) ran over that had no invoked
constraint in `DISPATCHCONSTRAINT`, so their generic constraints are absent from `sys`. They are
stored in `ext` as ISO 8601 strings, so they survive a `System` JSON round-trip.

# Arguments
- `sys`: a `System` built by `nem_system`.

# Returns
A `Vector{DateTime}`, empty when every interval had invoked constraints or no constraints were built
into `sys`.
"""
function get_missing_constraint_intervals(sys)
    return DateTime[DateTime(String(t)) for t in get(get_ext(sys), "missing_constraint_intervals", String[])]
end


"""
    get_defaulted_constraint_weights(sys) -> Vector{String}

The versioned names of the constraints [`nem_system`](@ref) built with the default
`constraint_weight` of 1.0 because `GENCONDATA.GENERICCONSTRAINTWEIGHT` was NULL.

# Arguments
- `sys`: a `System` built by `nem_system`.

# Returns
A `Vector{String}`, empty when no weight was defaulted or no constraints were built into `sys`.
"""
function get_defaulted_constraint_weights(sys)
    return collect(String, get(get_ext(sys), "defaulted_constraint_weights", String[]))
end
