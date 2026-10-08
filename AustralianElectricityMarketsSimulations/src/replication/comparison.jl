"Metric groups of the three-way comparison, in report order."
const COMPARISON_GROUPS = [
    "regional_rop", "fcas_rop", "interconnector_flow", "interconnector_loss", "dispatch_mw",
]

# Per-group agreement tolerance, in the group's unit (dollars per MWh or MW).
const COMPARISON_TOLERANCES = Dict(
    "regional_rop" => 1.0, "fcas_rop" => 1.0, "interconnector_flow" => 5.0,
    "interconnector_loss" => 3.0, "dispatch_mw" => 1.0,
)

"Approximate size in MB of one NEMDE case-file zip (one market day) on NEMWEB."
const NEMDE_DAY_ZIP_MB = 170

const _COMPARISON_CLASSES = ["both_match", "nempy_only", "aemsim_only", "both_off_equal", "neither"]

const _EMPTY_NEMPY = DataFrame(
    interval = DateTime[], metric_group = String[], key = String[],
    nempy = Union{Missing, Float64}[], nemde = Union{Missing, Float64}[],
)

# Market day (04:00 to 04:00) that holds the dispatch interval ending at `t`.
_market_day(t::DateTime) = Date(t - Hour(4) - Second(1))

"""
    comparison_intervals(from, to) -> Vector{DateTime}

Every dispatch interval (`SETTLEMENTDATE`, the interval end) of the NEM market days `from` to `to`
inclusive. Market day `D` runs from `D 04:05` to `D+1 04:00` in 5-minute steps.

# Arguments
- `from`, `to`: `Date`s, the first and last market day.

# Returns
A sorted `Vector{DateTime}`, 288 per market day.
"""
function comparison_intervals(from::Date, to::Date)
    from <= to || throw(ArgumentError("from ($from) is after to ($to)"))
    days = from:Day(1):to
    return reduce(
        vcat, (collect((DateTime(d) + Hour(4) + DISPATCH_INTERVAL):DISPATCH_INTERVAL:(DateTime(d + Day(1)) + Hour(4))) for d in days)
    )
end

"""
    comparison_sample(from, to; n = 100, seed = 1, days = min(n, 10)) -> Vector{DateTime}

Draws `n` distinct dispatch intervals uniformly at random from the market days `from` to `to`,
restricted to `days` randomly chosen market days so that the NEMDE case-file downloads stay bounded.
The draw depends only on `seed` and the dates, not on the Julia version.

# Arguments
- `from`, `to`: `Date`s, the first and last market day.
- `n`: the number of intervals; fewer are returned when the chosen days hold fewer.
- `seed`: the integer that orders days and intervals.
- `days`: the number of market days to draw from, capped at the number in the range.

# Returns
A sorted, duplicate-free `Vector{DateTime}` of interval ends on the 5-minute grid.
"""
function comparison_sample(from::Date, to::Date; n::Integer = 100, seed::Integer = 1, days::Integer = min(n, 10))
    n > 0 || throw(ArgumentError("n must be positive"))
    days > 0 || throw(ArgumentError("days must be positive"))
    useed = UInt64(seed)
    order(x) = _mix(useed ⊻ _mix(UInt64(Dates.value(x))))
    market_days = collect(from:Day(1):to)
    isempty(market_days) && throw(ArgumentError("from ($from) is after to ($to)"))
    chosen = sort!(sort(market_days; by = order)[1:min(days, length(market_days))])
    pool = reduce(vcat, (comparison_intervals(d, d) for d in chosen))
    drawn = sort(pool; by = order)[1:min(n, length(pool))]
    return sort!(drawn)
end

"""
    comparison_download_mb(intervals) -> Int

Estimated NEMWEB download in MB to fetch the NEMDE case files of `intervals`: one zip of
about `NEMDE_DAY_ZIP_MB` MB per distinct market day.

# Arguments
- `intervals`: a vector of `DateTime` interval ends.

# Returns
The estimate as an `Int`.
"""
comparison_download_mb(intervals) = NEMDE_DAY_ZIP_MB * length(unique(_market_day.(intervals)))

# FCAS keys read `REGION/SERVICE`; AEMSim's enum print `REGION/BidType.SERVICE = n` is reduced to it.
function _service_key(region::AbstractString, bidtype::AbstractString)
    m = match(r"([A-Z0-9]+)(?: = \d+)?$", bidtype)
    return "$region/$(isnothing(m) ? bidtype : m.captures[1])"
end

function _normalise_key(group::AbstractString, key::AbstractString)
    group == "fcas_rop" || return String(key)
    region, rest = split(key, '/'; limit = 2)
    return _service_key(region, rest)
end

"""
    aemsim_long(table) -> DataFrame

Reshapes a [`run_validation`](@ref) table (or the `ours`/`published` rows of
[`replicate_interval`](@ref)) into the comparison layout: failure rows are dropped and FCAS keys
become `REGION/SERVICE`.

# Arguments
- `table`: a `DataFrame` with `interval`, `metric_family`, `key`, `ours` and `published`.

# Returns
A `DataFrame` with `interval`, `metric_group`, `key`, `aemsim` and `nemde`.
"""
function aemsim_long(table::DataFrame)
    rows = filter(:metric_family => in(COMPARISON_GROUPS), table)
    return DataFrame(;
        interval = rows.interval,
        metric_group = String.(rows.metric_family),
        key = [_normalise_key(g, k) for (g, k) in zip(rows.metric_family, rows.key)],
        aemsim = Union{Missing, Float64}[ismissing(x) ? missing : Float64(x) for x in rows.ours],
        nemde = Union{Missing, Float64}[ismissing(x) ? missing : Float64(x) for x in rows.published],
    )
end

"""
    nempy_stamp(interval) -> String

The `YYYY/MM/DD HH:MM:SS` text nempy and its harness use for the interval ending at `interval`.
"""
nempy_stamp(interval::DateTime) = Dates.format(interval, "yyyy/mm/dd HH:MM:SS")

"""
    nempy_tag(interval) -> String

The `YYYYMMDD_HHMMSS` name of the harness output directory of `interval`.
"""
nempy_tag(interval::DateTime) = Dates.format(interval, "yyyymmdd_HHMMSS")

# Splits one CSV line into fields, honouring double quotes.
function _split_csv(line::AbstractString)
    fields = String[]
    buf = IOBuffer()
    quoted = false
    chars = collect(line)
    i = 1
    while i <= length(chars)
        c = chars[i]
        if quoted
            if c == '"' && i < length(chars) && chars[i + 1] == '"'
                write(buf, '"')
                i += 1
            elseif c == '"'
                quoted = false
            else
                write(buf, c)
            end
        elseif c == '"'
            quoted = true
        elseif c == ','
            push!(fields, String(take!(buf)))
        else
            write(buf, c)
        end
        i += 1
    end
    push!(fields, String(take!(buf)))
    return fields
end

"""
    read_comparison_csv(path) -> DataFrame

Reads a CSV file into a `DataFrame` of `String` columns, with empty fields as `missing`. Fields may
be double-quoted but may not contain newlines.

# Arguments
- `path`: the file to read.

# Returns
A `DataFrame` with the header's column names; zero rows when the file holds only a header.
"""
function read_comparison_csv(path::AbstractString)
    lines = filter(!isempty, readlines(path))
    header = _split_csv(first(lines))
    cols = [Union{Missing, String}[] for _ in header]
    for line in lines[2:end]
        fields = _split_csv(line)
        for (j, col) in enumerate(cols)
            push!(col, j <= length(fields) && !isempty(fields[j]) ? fields[j] : missing)
        end
    end
    return DataFrame(cols, header)
end

_csv_field(x) = ismissing(x) ? "" : occursin(r"[,\"\n]", string(x)) ? "\"" * replace(string(x), "\"" => "\"\"", "\n" => " ") * "\"" : string(x)

"""
    write_comparison_csv(path, df; append = false) -> String

Writes `df` as CSV (a header unless appending to an existing file). `missing` is an empty field;
`DateTime`s are ISO text.

# Arguments
- `path`: the file to write.
- `df`: the `DataFrame`.
- `append`: add the rows to an existing file instead of replacing it.

# Returns
`path`.
"""
function write_comparison_csv(path::AbstractString, df::DataFrame; append::Bool = false)
    header = !(append && isfile(path) && filesize(path) > 0)
    open(path, append ? "a" : "w") do io
        header && println(io, join(names(df), ","))
        for r in eachrow(df)
            println(io, join((_csv_field(x) for x in r), ","))
        end
    end
    return path
end

_parse_float(x) = ismissing(x) ? missing : (v = tryparse(Float64, x); isnothing(v) ? missing : v)

"""
    read_nempy_interval(dir, interval) -> DataFrame

Reads the comparison files nempy's harness wrote for `interval` (`price_comparison.csv`,
`interconnector_comparison.csv`, `unit_comparison.csv`) into the layout of [`aemsim_long`](@ref).

# Arguments
- `dir`: the harness output root, holding one `YYYYMMDD_HHMMSS` directory per interval.
- `interval`: the interval end.

# Returns
A `DataFrame` with `interval`, `metric_group`, `key`, `nempy` and `nemde` (AEMO's value as the
harness read it). It has no rows when the interval has no output.
"""
function read_nempy_interval(dir::AbstractString, interval::DateTime)
    base = joinpath(dir, nempy_tag(interval))
    isdir(base) || return copy(_EMPTY_NEMPY)
    rows = NamedTuple[]
    row(group, key, value, published) = push!(
        rows, (; interval, metric_group = group, key = String(key), nempy = _parse_float(value), nemde = _parse_float(published)),
    )
    path = joinpath(base, "price_comparison.csv")
    if isfile(path)
        for r in eachrow(read_comparison_csv(path))
            r.service == "ENERGY" ? row("regional_rop", r.region, r.nempy_price, r.aemo_ROP) :
                row("fcas_rop", "$(r.region)/$(r.service)", r.nempy_price, r.aemo_ROP)
        end
    end
    path = joinpath(base, "interconnector_comparison.csv")
    if isfile(path)
        for r in eachrow(read_comparison_csv(path))
            row("interconnector_flow", r.interconnector, r.flow, r.MWFLOW)
            row("interconnector_loss", r.interconnector, r.losses, r.MWLOSSES)
        end
    end
    path = joinpath(base, "unit_comparison.csv")
    if isfile(path)
        for r in eachrow(read_comparison_csv(path))
            r.service == "TOTALCLEARED" && row("dispatch_mw", r.unit, r.nempy, r.aemo)
        end
    end
    return isempty(rows) ? copy(_EMPTY_NEMPY) : DataFrame(rows)
end

"""
    comparison_long(aemsim, nempy) -> DataFrame

Joins the AEMSim and nempy results on interval, metric group and key into one tidy table against
NEMDE's published value.

# Arguments
- `aemsim`: as returned by [`aemsim_long`](@ref); may be empty.
- `nempy`: as returned by [`read_nempy_interval`](@ref), stacked over intervals; may be empty.

# Returns
A `DataFrame` with `interval`, `metric_group`, `key`, `nemde`, `nempy`, `aemsim`, `gap_nempy` and
`gap_aemsim` (each source minus `nemde`, `missing` when either is), sorted by group order, interval
and key. `nemde` is AEMSim's published value, or nempy's when AEMSim has no row.
"""
function comparison_long(aemsim::DataFrame, nempy::DataFrame)
    a = isempty(aemsim) ? DataFrame(interval = DateTime[], metric_group = String[], key = String[], aemsim = Union{Missing, Float64}[], nemde_a = Union{Missing, Float64}[]) :
        rename(aemsim, :nemde => :nemde_a)
    n = isempty(nempy) ? DataFrame(interval = DateTime[], metric_group = String[], key = String[], nempy = Union{Missing, Float64}[], nemde_n = Union{Missing, Float64}[]) :
        rename(nempy, :nemde => :nemde_n)
    joined = outerjoin(unique(a, [:interval, :metric_group, :key]), unique(n, [:interval, :metric_group, :key]); on = [:interval, :metric_group, :key])
    gap(x, y) = ismissing(x) || ismissing(y) ? missing : x - y
    nemde = [coalesce(x, y, missing) for (x, y) in zip(joined.nemde_a, joined.nemde_n)]
    long = DataFrame(;
        interval = joined.interval, metric_group = joined.metric_group, key = joined.key,
        nemde = Union{Missing, Float64}[x for x in nemde],
        nempy = Union{Missing, Float64}[x for x in joined.nempy],
        aemsim = Union{Missing, Float64}[x for x in joined.aemsim],
    )
    long.gap_nempy = Union{Missing, Float64}[gap(x, y) for (x, y) in zip(long.nempy, long.nemde)]
    long.gap_aemsim = Union{Missing, Float64}[gap(x, y) for (x, y) in zip(long.aemsim, long.nemde)]
    rank = Dict(g => i for (i, g) in enumerate(COMPARISON_GROUPS))
    long.rank = [get(rank, g, length(rank) + 1) for g in long.metric_group]
    sort!(long, [:rank, :interval, :key])
    return select!(long, Not(:rank))
end

# Absolute gaps of `gapcol` in `group`, optionally limited to keys passing `keep`.
function _abs_gaps(long, group, gapcol; keep = _ -> true)
    sub = filter(r -> r.metric_group == group && keep(r.key), long)
    return Float64[abs(x) for x in skipmissing(sub[!, gapcol])]
end

_stat(f, xs) = isempty(xs) ? missing : f(xs)

"""
    comparison_summary(long; tolerances = COMPARISON_TOLERANCES) -> DataFrame

The headline metrics of [`comparison_long`](@ref) for nempy and AEMSim, as absolute gaps to NEMDE.
Regional ROP: mean, median, p90, max, rows within tolerance. FCAS ROP: mean and max excluding and
including `TAS1`. Interconnector flow: mean, median, max, share within tolerance; loss: mean, max.
Dispatch: share within tolerance, rows beyond it, sum of gaps and missing share (published rows
the source has no value for).

# Arguments
- `long`: the table from [`comparison_long`](@ref).
- `tolerances`: `metric_group => tolerance`.

# Returns
A `DataFrame` with `metric`, `nempy` and `aemsim` (`missing` where the source has no rows).
"""
function comparison_summary(long::DataFrame; tolerances = COMPARISON_TOLERANCES)
    rows = NamedTuple[]
    add(metric, f) = push!(rows, (; metric, nempy = f(:gap_nempy), aemsim = f(:gap_aemsim)))
    rop_tol, fcas_tol = tolerances["regional_rop"], tolerances["fcas_rop"]
    flow_tol, loss_tol, mw_tol = tolerances["interconnector_flow"], tolerances["interconnector_loss"], tolerances["dispatch_mw"]
    total(group) = count(==(group), long.metric_group)
    gaps(group, col; keep = _ -> true) = _abs_gaps(long, group, col; keep)
    not_tas1 = k -> !startswith(k, "TAS1/")

    add("regional_rop_rows", c -> total("regional_rop"))
    add("regional_rop_mean_gap", c -> _stat(mean, gaps("regional_rop", c)))
    add("regional_rop_median_gap", c -> _stat(median, gaps("regional_rop", c)))
    add("regional_rop_p90_gap", c -> _stat(x -> quantile(x, 0.9), gaps("regional_rop", c)))
    add("regional_rop_max_gap", c -> _stat(maximum, gaps("regional_rop", c)))
    add("regional_rop_rows_within_tolerance", c -> count(<=(rop_tol), gaps("regional_rop", c)))
    add("fcas_rop_rows", c -> total("fcas_rop"))
    add("fcas_rop_mean_gap_excl_tas1", c -> _stat(mean, gaps("fcas_rop", c; keep = not_tas1)))
    add("fcas_rop_max_gap_excl_tas1", c -> _stat(maximum, gaps("fcas_rop", c; keep = not_tas1)))
    add("fcas_rop_mean_gap_incl_tas1", c -> _stat(mean, gaps("fcas_rop", c)))
    add("fcas_rop_max_gap_incl_tas1", c -> _stat(maximum, gaps("fcas_rop", c)))
    add("fcas_rop_rows_within_tolerance", c -> count(<=(fcas_tol), gaps("fcas_rop", c)))
    add("interconnector_flow_rows", c -> total("interconnector_flow"))
    add("interconnector_flow_mean_gap", c -> _stat(mean, gaps("interconnector_flow", c)))
    add("interconnector_flow_median_gap", c -> _stat(median, gaps("interconnector_flow", c)))
    add("interconnector_flow_max_gap", c -> _stat(maximum, gaps("interconnector_flow", c)))
    add("interconnector_flow_share_within_tolerance", c -> _stat(x -> count(<=(flow_tol), x) / length(x), gaps("interconnector_flow", c)))
    add("interconnector_loss_mean_gap", c -> _stat(mean, gaps("interconnector_loss", c)))
    add("interconnector_loss_max_gap", c -> _stat(maximum, gaps("interconnector_loss", c)))
    add("interconnector_loss_share_within_tolerance", c -> _stat(x -> count(<=(loss_tol), x) / length(x), gaps("interconnector_loss", c)))
    add("dispatch_mw_rows", c -> total("dispatch_mw"))
    add("dispatch_mw_share_within_tolerance", c -> _stat(x -> count(<=(mw_tol), x) / length(x), gaps("dispatch_mw", c)))
    add("dispatch_mw_rows_beyond_tolerance", c -> count(>(mw_tol), gaps("dispatch_mw", c)))
    add("dispatch_mw_sum_of_gaps", c -> sum(gaps("dispatch_mw", c)))
    add(
        "dispatch_mw_missing_share", c -> begin
            published = filter(r -> r.metric_group == "dispatch_mw" && !ismissing(r.nemde), long)
            col = c == :gap_nempy ? :nempy : :aemsim
            isempty(published) ? missing : count(ismissing, published[!, col]) / nrow(published)
        end,
    )
    out = DataFrame(rows)
    # A source with no values at all reports `missing` for counts as well as statistics.
    for (col, gapcol) in ((:nempy, :gap_nempy), (:aemsim, :gap_aemsim))
        any(!ismissing, long[!, gapcol]) || (out[!, col] = Union{Missing, Float64}[missing for _ in 1:nrow(out)])
    end
    return out
end

"""
    comparison_classify(long; tolerances = COMPARISON_TOLERANCES) -> DataFrame

Classifies every row that has all three values: `both_match` (nempy and AEMSim within tolerance of
NEMDE), `nempy_only`, `aemsim_only`, `both_off_equal` (both outside tolerance but within tolerance
of each other) or `neither`.

# Arguments
- `long`: the table from [`comparison_long`](@ref).
- `tolerances`: `metric_group => tolerance`.

# Returns
A `DataFrame` with `interval`, `metric_group`, `key` and `class` for the complete rows.
"""
function comparison_classify(long::DataFrame; tolerances = COMPARISON_TOLERANCES)
    complete = filter(r -> !ismissing(r.gap_nempy) && !ismissing(r.gap_aemsim) && haskey(tolerances, r.metric_group), long)
    function classify(r)
        tol = tolerances[r.metric_group]
        nempy_ok, aemsim_ok = abs(r.gap_nempy) <= tol, abs(r.gap_aemsim) <= tol
        return nempy_ok && aemsim_ok ? "both_match" : nempy_ok ? "nempy_only" : aemsim_ok ? "aemsim_only" :
            abs(r.nempy - r.aemsim) <= tol ? "both_off_equal" : "neither"
    end
    return DataFrame(;
        interval = complete.interval, metric_group = complete.metric_group, key = complete.key,
        class = String[classify(r) for r in eachrow(complete)],
    )
end

"""
    comparison_worst(long; n = 10) -> DataFrame

The `n` rows with the largest absolute gap per metric group and source.

# Arguments
- `long`: the table from [`comparison_long`](@ref).
- `n`: rows kept per group and source.

# Returns
A `DataFrame` with `metric_group`, `source` (`"nempy"` or `"aemsim"`), `interval`, `key`, `nemde`,
`value` and `gap`, ordered by group then largest gap first.
"""
function comparison_worst(long::DataFrame; n::Integer = 10)
    rows = NamedTuple[]
    for group in COMPARISON_GROUPS, source in ("nempy", "aemsim")
        gapcol = Symbol("gap_", source)
        sub = filter(r -> r.metric_group == group && !ismissing(r[gapcol]), long)
        for i in first(sortperm(abs.(sub[!, gapcol]); rev = true), n)
            r = sub[i, :]
            push!(rows, (; metric_group = group, source, interval = r.interval, key = r.key, nemde = r.nemde, value = r[Symbol(source)], gap = r[gapcol]))
        end
    end
    isempty(rows) && return DataFrame(
        metric_group = String[], source = String[], interval = DateTime[], key = String[],
        nemde = Float64[], value = Float64[], gap = Float64[],
    )
    return DataFrame(rows)
end

_fmt(x::Missing) = "n/a"
_fmt(x::Integer) = string(x)
_fmt(x::AbstractFloat) = isinteger(x) && abs(x) < 1.0e9 ? string(Int(x)) : string(round(x; sigdigits = 3))
_fmt(x::DateTime) = Dates.format(x, "yyyy-mm-dd HH:MM")
_fmt(x) = string(x)

function _md_table(df::DataFrame)
    head = "| " * join(names(df), " | ") * " |"
    rule = "| " * join(("---" for _ in names(df)), " | ") * " |"
    body = ["| " * join((_fmt(x) for x in r), " | ") * " |" for r in eachrow(df)]
    return join([head, rule, body...], "\n")
end

"""
    comparison_markdown(long, status; skipped = nothing, tolerances = COMPARISON_TOLERANCES) -> String

Renders the comparison report: run counts and solve times, the headline metrics, the three-way
classification, AEMSim's skipped constraints and the worst rows per metric.

# Arguments
- `long`: the table from [`comparison_long`](@ref).
- `status`: a `DataFrame` with one row per AEMSim interval: `interval`, `status` (`"ok"` or
  `"failed"`), `seconds` and `message`.
- `skipped`: an optional `DataFrame` with `interval`, `constraint` and `reason`, the skipped
  constraints of every solved interval.
- `tolerances`: `metric_group => tolerance`.

# Returns
The Markdown text.
"""
function comparison_markdown(
        long::DataFrame, status::DataFrame; skipped::Union{Nothing, DataFrame} = nothing, tolerances = COMPARISON_TOLERANCES,
    )
    io = IOBuffer()
    intervals = unique(long.interval)
    solved = filter(:status => ==("ok"), status)
    failed = filter(:status => ==("failed"), status)
    println(io, "# Dispatch comparison: NEMDE, nempy and AEMSim\n")
    println(io, "Gaps are absolute differences to NEMDE's published value.")
    println(io, "Tolerances: ", join(("$g $(tolerances[g])" for g in COMPARISON_GROUPS), ", "), ".\n")
    println(io, "## Run\n")
    println(io, "- Intervals with results: ", length(intervals))
    println(io, "- AEMSim intervals solved: ", nrow(solved), "; failed: ", nrow(failed))
    if !isempty(failed)
        for r in eachrow(failed)
            println(io, "  - ", _fmt(r.interval), ": ", ismissing(r.message) ? "" : r.message)
        end
    end
    secs = Float64[x for x in skipmissing(solved.seconds)]
    if !isempty(secs)
        println(
            io, "- Solve time (s): mean ", _fmt(mean(secs)), ", median ", _fmt(median(secs)),
            ", p90 ", _fmt(quantile(secs, 0.9)), ", max ", _fmt(maximum(secs))
        )
    end
    println(io, "\n## Headline metrics\n")
    println(io, _md_table(comparison_summary(long; tolerances)), "\n")
    println(io, "## Three-way classification\n")
    classified = comparison_classify(long; tolerances)
    counts = DataFrame(; metric_group = COMPARISON_GROUPS)
    for class in _COMPARISON_CLASSES
        counts[!, class] = [count(r -> r.metric_group == g && r.class == class, eachrow(classified)) for g in COMPARISON_GROUPS]
    end
    println(io, _md_table(counts), "\n")
    if !isnothing(skipped)
        println(io, "## Skipped constraints (AEMSim)\n")
        if isempty(skipped)
            println(io, "None.\n")
        else
            per = combine(groupby(skipped, [:reason, :interval]), nrow => :n)
            by_reason = combine(
                groupby(per, :reason), :n => sum => :total, :n => minimum => :min_per_interval, :n => maximum => :max_per_interval,
            )
            distinct = combine(groupby(skipped, :reason), :constraint => (x -> length(unique(x))) => :distinct_constraints)
            println(io, _md_table(sort(innerjoin(by_reason, distinct; on = :reason), :reason)), "\n")
        end
    end
    println(io, "## Worst rows\n")
    worst = comparison_worst(long)
    for group in COMPARISON_GROUPS
        println(io, "### ", group, "\n")
        sub = select(filter(:metric_group => ==(group), worst), Not(:metric_group))
        println(io, isempty(sub) ? "No rows.\n" : _md_table(sub) * "\n")
    end
    return String(take!(io))
end
