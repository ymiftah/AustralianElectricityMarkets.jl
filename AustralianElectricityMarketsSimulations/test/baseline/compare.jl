# Compares two replay snapshots key by key. Run as a script, it compares two capture folders and
# exits 0 when the gate passes.

using Dates
using DataFrames
using Serialization

# Kinds whose values gate the comparison; `parameter` and `input` differences are reported only.
const _GATING_KINDS = ("variable", "dual", "aux", "expression", "stats", "derived")
const _STATS_RTOL = 1.0e-9
const _STATS_GATING_COLUMNS = ("objective_value",)
# The duals that gate in invariants mode: the regional power-balance rows `read_prices` reads.
const _ENERGY_PRICE_DUAL_KEY = "dual/CopperPlateBalanceConstraint__Area"
const _FCAS_DUAL_PREFIX = "dual/NEMConstraintLimit__GenericConstraint__"
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

# `b` without the rows whose non-numeric columns are absent from `a` and whose values are all within `atol` of
# zero (the zero-width rows of a wider axis); other extra rows stay so that the tables differ.
function _drop_zero_extra_rows(a::DataFrame, b::DataFrame, atol::Real)
    Set(names(a)) == Set(names(b)) || return b
    rows = _row_columns(a)
    isempty(rows) && return b
    known = Set(Tuple(r[c] for c in rows) for r in eachrow(a))
    vals = _value_columns(b)
    keep = [
        Tuple(r[c] for c in rows) in known || any(c -> !(ismissing(r[c]) || abs(r[c]) <= atol), vals)
            for r in eachrow(b)
    ]
    return b[keep, :]
end

# The largest gap of two tables aligned on their non-numeric columns, and whether they differ.
# Tables with other columns or row counts differ outright.
function _compare_tables(kind::AbstractString, a::DataFrame, b::DataFrame, atol::Real; extra_zero::Bool = false)
    extra_zero && (b = _drop_zero_extra_rows(a, b, atol))
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

# The FCAS requirement map (constraint, region, service) of a snapshot pair; the candidate's wins.
function _fcas_requirements(baseline::AbstractDict, candidate::AbstractDict)
    for snap in (candidate, baseline)
        haskey(snap, "input/fcas_requirements") && return snap["input/fcas_requirements"]
    end
    throw(ArgumentError("invariants mode needs input/fcas_requirements in at least one snapshot."))
end

# The sum of the FCAS requirement duals per (interval, region, direction), the quantity that is unique at
# degenerate points: the duals of twin requirement rows (for example R6 and R60) are not, but their sum is.
# Each (constraint, region, service) requirement adds its constraint's dual, as `read_fcas_prices` does,
# and the direction is `RAISE` or `LOWER` from the service name. Keys are `derived/fcas_sum__<direction>`.
function _fcas_dual_sums(snapshot::AbstractDict, requirements::DataFrame)
    sums = Dict{String, Dict{Tuple{DateTime, String}, Float64}}()
    for r in eachrow(requirements)
        key = _FCAS_DUAL_PREFIX * r.constraint
        haskey(snapshot, key) || continue
        direction = startswith(r.service, "RAISE") ? "RAISE" : startswith(r.service, "LOWER") ? "LOWER" : r.service
        acc = get!(sums, "derived/fcas_sum__$direction", Dict{Tuple{DateTime, String}, Float64}())
        for row in eachrow(snapshot[key])
            id = (row.DateTime, r.region)
            acc[id] = get(acc, id, 0.0) + row.value
        end
    end
    out = Dict{String, DataFrame}()
    for (key, acc) in sums
        ids = sort!(collect(keys(acc)))
        out[key] = DataFrame(DateTime = first.(ids), name = last.(ids), value = [acc[i] for i in ids])
    end
    return out
end

# The snapshot reduced to the gating set of invariants mode: everything but the duals, the energy price
# duals, and the derived FCAS dual sums. The remaining duals are returned separately as the reported set.
function _invariant_view(snapshot::AbstractDict, requirements::DataFrame)
    gating = Dict{String, DataFrame}(k => v for (k, v) in snapshot if _kind(k) != "dual" || k == _ENERGY_PRICE_DUAL_KEY)
    merge!(gating, _fcas_dual_sums(snapshot, requirements))
    reported = Dict{String, DataFrame}(k => v for (k, v) in snapshot if _kind(k) == "dual" && k != _ENERGY_PRICE_DUAL_KEY)
    return gating, reported
end

_allowed(key::AbstractString, patterns) = any(p -> occursin(p, key), patterns)

# Every gating key that is measured or missing on one side, with its largest gap and whether it fails.
function _gate_rows(
        baseline::AbstractDict, candidate::AbstractDict; atol::Real, allow_new, allow_missing, mask_gc_slacks::Bool,
        invariants::Bool = false, report_only = Regex[],
    )
    if invariants
        requirements = _fcas_requirements(baseline, candidate)
        baseline, _ = _invariant_view(baseline, requirements)
        candidate, _ = _invariant_view(candidate, requirements)
    end
    if mask_gc_slacks
        baseline = _mask_gc_slacks(baseline)
        candidate = _mask_gc_slacks(candidate)
    end
    rows = NamedTuple{(:key, :kind, :max_abs, :mismatch, :report), Tuple{String, String, Float64, Bool, Bool}}[]
    for key in sort!(collect(union(keys(baseline), keys(candidate))))
        kind = _kind(key)
        kind in _GATING_KINDS || continue
        report = _allowed(key, report_only)
        if !haskey(candidate, key)
            _allowed(key, allow_missing) || push!(rows, (; key, kind, max_abs = Inf, mismatch = !report, report))
        elseif !haskey(baseline, key)
            _allowed(key, allow_new) || push!(rows, (; key, kind, max_abs = Inf, mismatch = !report, report))
        else
            cmp = _compare_tables(kind, baseline[key], candidate[key], atol; extra_zero = _allowed(key, allow_new))
            push!(rows, (; key, kind, cmp.max_abs, mismatch = cmp.mismatch && !report, report = cmp.mismatch && report))
        end
    end
    return rows
end

"""
    compare_snapshots(baseline, candidate; atol = 1.0e-9, allow_new = Regex[], allow_missing = Regex[], mask_gc_slacks = false) -> Vector{NamedTuple}

Compares two snapshots from [`replay_snapshot`](@ref) and returns the gating mismatches as
`(; key, kind, max_abs)` rows. Variable, dual, auxiliary and expression values differ when they exceed
`atol`; the optimizer objective differs beyond a relative `1e-9`. Parameter and input tables never gate.
A key present on one side only is a mismatch unless a regex in `allow_new` or `allow_missing` matches it;
rows that a key matching `allow_new` adds with all values zero do not count as a difference.

# Arguments
- `baseline`, `candidate`: the snapshots to compare.
- `atol`: the absolute tolerance on each value.
- `allow_new`, `allow_missing`: regexes of keys the candidate may add or lack.
- `mask_gc_slacks`: whether generic-constraint slacks are multiplied by the invoked series on both sides
  before comparing.
- `report_only`: regexes of keys that are compared but never gate (see the `--report-only` CLI option).
- `invariants`: gate only the quantities unique at degenerate points: variables, auxiliary variables,
  expressions, the objective, the energy price duals (`CopperPlateBalanceConstraint`) and the sum of the
  FCAS requirement duals per (interval, region, direction), `RAISE` or `LOWER`. Other duals do not gate
  (see [`reported_dual_differences`](@ref)). Needs `input/fcas_requirements` in a snapshot.

# Returns
A `Vector` of `(; key, kind, max_abs)` named tuples, empty when the snapshots agree.
"""
function compare_snapshots(
        baseline::AbstractDict, candidate::AbstractDict; atol::Real = 1.0e-9,
        allow_new::AbstractVector{Regex} = Regex[], allow_missing::AbstractVector{Regex} = Regex[],
        mask_gc_slacks::Bool = false, invariants::Bool = false, report_only::AbstractVector{Regex} = Regex[],
    )
    rows = _gate_rows(baseline, candidate; atol, allow_new, allow_missing, mask_gc_slacks, invariants, report_only)
    return [(; key = r.key, kind = r.kind, max_abs = r.max_abs) for r in rows if r.mismatch]
end

"""
    reported_dual_differences(baseline, candidate; atol = 1.0e-9) -> Vector{NamedTuple}

The duals that do not gate in invariants mode (every dual but the energy price duals) that differ
beyond `atol` or are on one side only, as `(; key, kind, max_abs)` rows sorted by decreasing gap.
"""
function reported_dual_differences(baseline::AbstractDict, candidate::AbstractDict; atol::Real = 1.0e-9)
    requirements = _fcas_requirements(baseline, candidate)
    _, rb = _invariant_view(baseline, requirements)
    _, rc = _invariant_view(candidate, requirements)
    rows = NamedTuple{(:key, :kind, :max_abs), Tuple{String, String, Float64}}[]
    for key in union(keys(rb), keys(rc))
        if haskey(rb, key) && haskey(rc, key)
            cmp = _compare_tables("dual", rb[key], rc[key], atol)
            cmp.mismatch && push!(rows, (; key, kind = "dual", cmp.max_abs))
        else
            push!(rows, (; key, kind = "dual", max_abs = Inf))
        end
    end
    return sort!(rows; by = r -> r.max_abs, rev = true)
end

"""
    max_parameter_difference(baseline, candidate) -> NamedTuple

The largest gap among the `parameter/` tables present in both snapshots, reported and never gating.

# Returns
`(; key, max_abs)`, with an empty `key` and `max_abs = 0.0` when no parameter table is shared.
"""
function max_parameter_difference(baseline::AbstractDict, candidate::AbstractDict)
    best = (key = "", max_abs = -Inf)
    for key in keys(baseline)
        _kind(key) == "parameter" && haskey(candidate, key) || continue
        gap = _compare_tables("parameter", baseline[key], candidate[key], 0.0).max_abs
        gap > best.max_abs && (best = (; key, max_abs = gap))
    end
    return best.max_abs == -Inf ? (key = "", max_abs = 0.0) : best
end

function _parse_compare_args(args::Vector{String})
    positional = String[]
    atol = 1.0e-9
    allow_new = Regex[]
    allow_missing = Regex[]
    mask = false
    invariants = false
    report_only = Regex[]
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
        elseif arg == "--report-only"
            push!(report_only, Regex(args[i + 1])); i += 2
        elseif arg == "--invariants"
            invariants = true; i += 1
        elseif startswith(arg, "--")
            error("unknown option $arg")
        else
            push!(positional, arg); i += 1
        end
    end
    length(positional) == 2 || error(
        "usage: compare.jl BASELINE_DIR CANDIDATE_DIR [--atol X] [--allow-new REGEX]... [--allow-missing REGEX]... [--mask-gc-slacks] [--invariants] [--report-only REGEX]...",
    )
    return (; baseline = positional[1], candidate = positional[2], atol, allow_new, allow_missing, mask, invariants, report_only)
end

# Prints the gate verdict for two capture folders; returns the process exit code.
function _compare_main(args::Vector{String})
    opts = _parse_compare_args(args)
    baseline = deserialize(joinpath(opts.baseline, "snapshot.jls"))
    candidate = deserialize(joinpath(opts.candidate, "snapshot.jls"))
    rows = _gate_rows(
        baseline, candidate; atol = opts.atol, allow_new = opts.allow_new,
        allow_missing = opts.allow_missing, mask_gc_slacks = opts.mask, invariants = opts.invariants,
        report_only = opts.report_only,
    )
    failures = sort([r for r in rows if r.mismatch]; by = r -> r.max_abs, rev = true)
    worst = maximum((r.max_abs for r in rows if !r.mismatch); init = 0.0)
    report_rows = sort([r for r in rows if r.report]; by = r -> r.max_abs, rev = true)
    isempty(report_rows) || println("report-only differences: $(length(report_rows)) key(s)")
    for r in first(report_rows, 10)
        println("  $(r.key)  max|Δ|=$(r.max_abs)")
    end
    param = max_parameter_difference(baseline, candidate)
    if isempty(failures)
        println("GATE PASS max|Δ|=$(worst)")
    else
        println("GATE FAIL $(length(failures)) mismatched key(s); worst 10:")
        for r in first(failures, 10)
            println("  $(r.key)  kind=$(r.kind)  max|Δ|=$(r.max_abs)")
        end
    end
    if opts.invariants
        reported = reported_dual_differences(baseline, candidate; atol = opts.atol)
        kinds = Dict{String, Int}()
        for r in reported
            k = replace(r.key, _FCAS_DUAL_PREFIX => "NEMConstraintLimit/", r"^dual/" => "")
            k = first(split(k, "__"; limit = 2))
            kinds[k] = get(kinds, k, 0) + 1
        end
        println("non-gating dual differences: $(length(reported)) key(s) by kind $(sort!(collect(kinds)))")
        for r in first(reported, 10)
            println("  $(r.key)  max|Δ|=$(r.max_abs)")
        end
    end
    println("parameter max|Δ|=$(param.max_abs) at $(isempty(param.key) ? "(none)" : param.key)")
    return isempty(failures) ? 0 : 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(_compare_main(collect(String, ARGS)))
end
