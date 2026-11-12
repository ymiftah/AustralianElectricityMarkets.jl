# Compares two replay snapshots key by key. Run as a script, it compares two capture folders and
# exits 0 when the gate passes.

using DataFrames
using Serialization

# Kinds whose values gate the comparison; `parameter` and `input` differences are reported only.
const _GATING_KINDS = ("variable", "dual", "aux", "expression", "stats")
const _STATS_RTOL = 1.0e-9
const _STATS_GATING_COLUMNS = ("objective_value",)
const _GC_SLACK_PREFIXES = ("variable/GenericConstraintSlackUp", "variable/GenericConstraintSlackDown")

_kind(key::AbstractString) = first(split(key, "/"; limit = 2))

_unmeasured(x) = ismissing(x) || (x isa AbstractFloat && isnan(x))

# The gap between two cells: `0.0` when both are unmeasured, `Inf` when only one is.
function _gap(x, y)
    xu, yu = _unmeasured(x), _unmeasured(y)
    xu && yu && return 0.0
    (xu || yu) && return Inf
    return abs(float(x) - float(y))
end

# Whether two cells differ: beyond `atol`, or beyond `_STATS_RTOL` relative for the statistics.
function _exceeds(kind::AbstractString, x, y, atol::Real)
    gap = _gap(x, y)
    isinf(gap) && return true
    tol = kind == "stats" ? max(atol, _STATS_RTOL * max(abs(x), abs(y))) : atol
    return gap > tol
end

_row_columns(table::DataFrame) = [n for n in names(table) if !(nonmissingtype(eltype(table[!, n])) <: Real)]
_value_columns(table::DataFrame) = [n for n in names(table) if nonmissingtype(eltype(table[!, n])) <: Real]

# The largest gap of two tables aligned on their non-numeric columns, and whether they differ.
# Tables with other columns or row counts differ outright.
function _compare_tables(kind::AbstractString, a::DataFrame, b::DataFrame, atol::Real)
    Set(names(a)) == Set(names(b)) && nrow(a) == nrow(b) || return (max_abs = Inf, mismatch = true)
    b = b[!, names(a)]
    rows = _row_columns(a)
    sa = isempty(rows) ? a : sort(a, rows)
    sb = isempty(rows) ? b : sort(b, rows)
    all(c -> all(isequal.(sa[!, c], sb[!, c])), rows) || return (max_abs = Inf, mismatch = true)
    values = kind == "stats" ? intersect(_STATS_GATING_COLUMNS, _value_columns(a)) : _value_columns(a)
    max_abs = 0.0
    mismatch = false
    for c in values, (x, y) in zip(sa[!, c], sb[!, c])
        max_abs = max(max_abs, _gap(x, y))
        mismatch |= _exceeds(kind, x, y, atol)
    end
    return (; max_abs, mismatch)
end

# The `invoked` column of `name` in `snapshot`, at the stamps of `table`.
function _invoked_factor(snapshot::AbstractDict, stamps, name::AbstractString)
    haskey(snapshot, "input/constraint_invoked") || throw(
        ArgumentError("mask_gc_slacks needs input/constraint_invoked in both snapshots."),
    )
    invoked = snapshot["input/constraint_invoked"]
    name in names(invoked) || throw(ArgumentError("input/constraint_invoked has no column for \"$name\"."))
    column = Dict(zip(invoked.DateTime, invoked[!, name]))
    return [column[t] for t in stamps]
end

# A copy of `snapshot` whose generic-constraint slack tables are multiplied by the invoked series.
function _mask_gc_slacks(snapshot::AbstractDict)
    masked = copy(snapshot)
    for key in keys(snapshot)
        prefix = first(split(key, "__"; limit = 2))
        prefix in _GC_SLACK_PREFIXES || continue
        name = last(split(key, "__"; limit = 3))
        table = copy(snapshot[key])
        factor = _invoked_factor(snapshot, table.DateTime, name)
        for c in _value_columns(table)
            table[!, c] = table[!, c] .* factor
        end
        masked[key] = table
    end
    return masked
end

_allowed(key::AbstractString, patterns) = any(p -> occursin(p, key), patterns)

# Every gating key that is measured or missing on one side, with its largest gap and whether it fails.
function _gate_rows(
        baseline::AbstractDict, candidate::AbstractDict; atol::Real, allow_new, allow_missing, mask_gc_slacks::Bool,
    )
    if mask_gc_slacks
        baseline = _mask_gc_slacks(baseline)
        candidate = _mask_gc_slacks(candidate)
    end
    rows = NamedTuple{(:key, :kind, :max_abs, :mismatch), Tuple{String, String, Float64, Bool}}[]
    for key in sort!(collect(union(keys(baseline), keys(candidate))))
        kind = _kind(key)
        kind in _GATING_KINDS || continue
        if !haskey(candidate, key)
            _allowed(key, allow_missing) || push!(rows, (; key, kind, max_abs = Inf, mismatch = true))
        elseif !haskey(baseline, key)
            _allowed(key, allow_new) || push!(rows, (; key, kind, max_abs = Inf, mismatch = true))
        else
            cmp = _compare_tables(kind, baseline[key], candidate[key], atol)
            push!(rows, (; key, kind, cmp.max_abs, cmp.mismatch))
        end
    end
    return rows
end

"""
    compare_snapshots(baseline, candidate; atol = 1.0e-9, allow_new = Regex[], allow_missing = Regex[], mask_gc_slacks = false) -> Vector{NamedTuple}

Compares two snapshots from [`replay_snapshot`](@ref) and returns the gating mismatches as
`(; key, kind, max_abs)` rows. Variable, dual, auxiliary and expression values differ when they exceed
`atol`; the optimizer objective differs beyond a relative `1e-9`. Parameter and input tables never gate.
A key present on one side only is a mismatch unless a regex in `allow_new` or `allow_missing` matches it.

# Arguments
- `baseline`, `candidate`: the snapshots to compare.
- `atol`: the absolute tolerance on each value.
- `allow_new`, `allow_missing`: regexes of keys the candidate may add or lack.
- `mask_gc_slacks`: whether generic-constraint slacks are multiplied by the invoked series on both sides
  before comparing.

# Returns
A `Vector` of `(; key, kind, max_abs)` named tuples, empty when the snapshots agree.
"""
function compare_snapshots(
        baseline::AbstractDict, candidate::AbstractDict; atol::Real = 1.0e-9,
        allow_new::AbstractVector{Regex} = Regex[], allow_missing::AbstractVector{Regex} = Regex[],
        mask_gc_slacks::Bool = false,
    )
    rows = _gate_rows(baseline, candidate; atol, allow_new, allow_missing, mask_gc_slacks)
    return [(; key = r.key, kind = r.kind, max_abs = r.max_abs) for r in rows if r.mismatch]
end

"""
    max_parameter_difference(baseline, candidate) -> NamedTuple

The largest gap among the `parameter/` tables present in both snapshots, reported and never gating.

# Returns
`(; key, max_abs)`, with an empty `key` and `max_abs = 0.0` when no parameter table is shared.
"""
function max_parameter_difference(baseline::AbstractDict, candidate::AbstractDict)
    best = (key = "", max_abs = 0.0)
    for key in keys(baseline)
        _kind(key) == "parameter" && haskey(candidate, key) || continue
        gap = _compare_tables("parameter", baseline[key], candidate[key], 0.0).max_abs
        gap > best.max_abs && (best = (; key, max_abs = gap))
    end
    return best
end

function _parse_compare_args(args::Vector{String})
    positional = String[]
    atol = 1.0e-9
    allow_new = Regex[]
    allow_missing = Regex[]
    mask = false
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--atol"
            atol = parse(Float64, args[i + 1]); i += 2
        elseif arg == "--allow-new"
            push!(allow_new, Regex(args[i + 1])); i += 2
        elseif arg == "--allow-missing"
            push!(allow_missing, Regex(args[i + 1])); i += 2
        elseif arg == "--mask-gc-slacks"
            mask = true; i += 1
        elseif startswith(arg, "--")
            error("unknown option $arg")
        else
            push!(positional, arg); i += 1
        end
    end
    length(positional) == 2 || error(
        "usage: compare.jl BASELINE_DIR CANDIDATE_DIR [--atol X] [--allow-new REGEX]... [--allow-missing REGEX]... [--mask-gc-slacks]",
    )
    return (; baseline = positional[1], candidate = positional[2], atol, allow_new, allow_missing, mask)
end

# Prints the gate verdict for two capture folders; returns the process exit code.
function _compare_main(args::Vector{String})
    opts = _parse_compare_args(args)
    baseline = deserialize(joinpath(opts.baseline, "snapshot.jls"))
    candidate = deserialize(joinpath(opts.candidate, "snapshot.jls"))
    rows = _gate_rows(
        baseline, candidate; atol = opts.atol, allow_new = opts.allow_new,
        allow_missing = opts.allow_missing, mask_gc_slacks = opts.mask,
    )
    failures = sort([r for r in rows if r.mismatch]; by = r -> r.max_abs, rev = true)
    worst = maximum((r.max_abs for r in rows if !r.mismatch); init = 0.0)
    param = max_parameter_difference(baseline, candidate)
    if isempty(failures)
        println("GATE PASS max|Δ|=$(worst)")
    else
        println("GATE FAIL $(length(failures)) mismatched key(s); worst 10:")
        for r in first(failures, 10)
            println("  $(r.key)  kind=$(r.kind)  max|Δ|=$(r.max_abs)")
        end
    end
    println("parameter max|Δ|=$(param.max_abs) at $(isempty(param.key) ? "(none)" : param.key)")
    return isempty(failures) ? 0 : 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(_compare_main(collect(String, ARGS)))
end
