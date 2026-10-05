const VALIDATION_STRATA = [
    :intervention, :violated, :fcas_spike, :price_extreme_NSW1, :price_extreme_QLD1,
    :price_extreme_SA1, :price_extreme_TAS1, :price_extreme_VIC1, :no_binding, :binding, :ordinary,
]

# Default per-family tolerance for `validation_summary`, in the family's own unit (dollars per
# MWh or MW). Placeholders until they are set from a reference solver's own error.
const VALIDATION_TOLERANCES = Dict(
    "regional_rop" => 1.0, "fcas_rop" => 1.0, "interconnector_flow" => 5.0,
    "interconnector_loss" => 1.0, "dispatch_mw" => 1.0, "cs_violation_mw" => 1.0,
    "cs_units_violating" => 0.0,
)

# splitmix64 finaliser: a stable, seed-keyed ordering that does not depend on the Julia version.
function _mix(x::UInt64)
    x = (x ⊻ (x >> 30)) * 0xbf58476d1ce4e5b9
    x = (x ⊻ (x >> 27)) * 0x94d049bb133111eb
    return x ⊻ (x >> 31)
end

"""
    validation_sample(db, month; n = 20, seed = 1, strata = VALIDATION_STRATA, fcas_spike = 300.0,
                      extreme_quantile = 0.01) -> DataFrame

Draws a reproducible stratified sample of dispatch intervals from `month`, using only AEMO's
published data. Each stratum is a pool of intervals: an `intervention` run present, a
`violated` constraint, an FCAS price above `fcas_spike`, a regional `price_extreme_<REGION>`
(`ROP` in the region's top or bottom `extreme_quantile`), a `binding` network constraint, `no_binding`,
and `ordinary` (any interval). Strata are drawn round-robin in the order of `strata`, each taking the
next interval of its seed-ordered pool that no earlier stratum took, until `n` are drawn or every
pool is empty. Only intervals whose following interval is also published are eligible.

# Arguments
- `db`: an `AEMDB` connection with `DISPATCHPRICE` and `DISPATCHCONSTRAINT` cached for `month`.
- `month`: any `Date` in the month.
- `n`: the sample size.
- `seed`: the integer that orders each pool.
- `strata`: the strata to draw from, a subset of [`VALIDATION_STRATA`](@ref).
- `fcas_spike`: FCAS `ROP` threshold, dollars per MW per hour.
- `extreme_quantile`: tail probability that defines a regional price extreme.

# Returns
A `DataFrame` with columns `interval` (`DateTime`), `stratum` (`String`) and `intervention`
(`Int`), sorted by `interval`. An `intervention` interval is replicated on its physical run.
"""
function validation_sample(
        db, month::Date; n::Integer = 20, seed::Integer = 1, strata = VALIDATION_STRATA,
        fcas_spike::Real = 300.0, extreme_quantile::Real = 0.01,
    )
    first_day = Date(year(month), Dates.month(month), 1)
    start = DateTime(first_day) + DISPATCH_INTERVAL
    stop = DateTime(first_day + Month(1))
    intervals = start:DISPATCH_INTERVAL:stop
    window = start:DISPATCH_INTERVAL:(stop + DISPATCH_INTERVAL)
    prices = read_prices(db, window)
    published = Set(prices.SETTLEMENTDATE)
    eligible = sort!(filter(t -> t in published && (t + DISPATCH_INTERVAL) in published, collect(intervals)))

    flags = read_constraint_flags(db, intervals)
    flagged(col) = Set(flags.SETTLEMENTDATE[flags[!, col]])
    fcas = read_fcas_prices(db, window)
    spiking = Set(fcas.SETTLEMENTDATE[coalesce.(fcas.ROP .> fcas_spike, false)])
    physical = Set(read_prices(db, window; intervention = 1).SETTLEMENTDATE)

    pools = Dict{Symbol, Vector{DateTime}}(
        :intervention => filter(in(physical), eligible),
        :violated => filter(in(flagged(:violated)), eligible),
        :fcas_spike => filter(in(spiking), eligible),
        :binding => filter(in(flagged(:binding)), eligible),
        :no_binding => filter(!in(flagged(:binding)), eligible),
        :ordinary => eligible,
    )
    for region in unique(prices.REGIONID)
        rop = filter(:REGIONID => ==(region), prices)
        lo, hi = quantile(skipmissing(rop.ROP), [extreme_quantile, 1 - extreme_quantile])
        extreme = Set(rop.SETTLEMENTDATE[coalesce.((rop.ROP .<= lo) .| (rop.ROP .>= hi), false)])
        pools[Symbol("price_extreme_", region)] = filter(in(extreme), eligible)
    end

    useed = UInt64(seed)
    order(t) = _mix(useed ⊻ _mix(UInt64(Dates.value(t))))
    queues = Dict(s => sort(get(pools, s, DateTime[]); by = order) for s in strata)
    chosen = Dict{DateTime, Symbol}()
    while length(chosen) < n
        progressed = false
        for s in strata
            length(chosen) < n || break
            queue = queues[s]
            while !isempty(queue)
                t = popfirst!(queue)
                haskey(chosen, t) && continue
                chosen[t] = s
                progressed = true
                break
            end
        end
        progressed || break
    end
    times = sort!(collect(keys(chosen)))
    return DataFrame(;
        interval = times,
        stratum = [String(chosen[t]) for t in times],
        intervention = [Int(t in physical && chosen[t] == :intervention) for t in times],
    )
end

# One tidy row; `gap` is `ours - published`, `missing` when either side is.
_validation_row(interval, stratum, family, key, ours, published) = (;
    interval, stratum, metric_family = family, key = String(key),
    ours, published, gap = ismissing(ours) || ismissing(published) ? missing : ours - published,
)

const _EMPTY_VALIDATION = DataFrame(
    interval = DateTime[], stratum = String[], metric_family = String[], key = String[],
    ours = Union{Missing, Float64}[], published = Union{Missing, Float64}[], gap = Union{Missing, Float64}[],
)

function _comparison_rows(comparison, interval, stratum)
    rows = NamedTuple[]
    for r in eachrow(comparison.prices)
        push!(rows, _validation_row(interval, stratum, "regional_rop", r.REGIONID, r.ROP_solved, r.ROP_published))
    end
    for r in eachrow(comparison.fcas_prices)
        push!(rows, _validation_row(interval, stratum, "fcas_rop", "$(r.REGIONID)/$(r.BIDTYPE)", r.ROP_solved, r.ROP_published))
    end
    for r in eachrow(comparison.interconnectors)
        push!(rows, _validation_row(interval, stratum, "interconnector_flow", r.INTERCONNECTORID, r.MWFLOW_solved, r.MWFLOW_published))
        push!(rows, _validation_row(interval, stratum, "interconnector_loss", r.INTERCONNECTORID, r.MWLOSSES_solved, r.MWLOSSES_published))
    end
    for r in eachrow(comparison.dispatch)
        push!(rows, _validation_row(interval, stratum, "dispatch_mw", r.DUID, r.TOTALCLEARED_solved, r.TOTALCLEARED_published))
    end
    return rows
end

"""
    run_validation(db, sample; optimizer = HiGHS.Optimizer, log = nothing) -> DataFrame

Replicates each interval of `sample` with [`replicate_interval`](@ref) and collects the outcome
against AEMO's published one in one tidy table. An interval that fails to build or solve is
recorded as a row of family `failure` (its message in `key`) and the run continues.

# Arguments
- `db`: an `AEMDB` connection, as for [`replicate_interval`](@ref).
- `sample`: a `DataFrame` with `interval` and, optionally, `stratum` and `intervention`
  columns, as returned by [`validation_sample`](@ref), or a vector of `DateTime`.
- `optimizer`: the JuMP optimizer.
- `log`: an optional `IO` that receives one progress line per interval.

# Returns
A `DataFrame` with columns `interval`, `stratum`, `metric_family`, `key`, `ours`, `published`
and `gap` (`ours - published`). The families are `regional_rop`, `fcas_rop`,
`interconnector_flow`, `interconnector_loss`, `dispatch_mw` and `failure`.
"""
function run_validation(db, sample::DataFrame; optimizer = HiGHS.Optimizer, log::Union{Nothing, IO} = nothing)
    out = copy(_EMPTY_VALIDATION)
    for (i, r) in enumerate(eachrow(sample))
        stratum = hasproperty(sample, :stratum) ? String(r.stratum) : "unstratified"
        intervention = hasproperty(sample, :intervention) ? Int(r.intervention) : 0
        started = time()
        rows = try
            comparison = replicate_interval(db, r.interval; intervention = intervention, optimizer = optimizer).comparison
            _comparison_rows(comparison, r.interval, stratum)
        catch err
            msg = first(split(sprint(showerror, err), '\n'))
            [_validation_row(r.interval, stratum, "failure", msg, missing, missing)]
        end
        append!(out, DataFrame(rows); promote = true)
        isnothing(log) || println(log, "[$i/$(nrow(sample))] $(r.interval) $stratum $(round(time() - started; digits = 1)) s")
        isnothing(log) || flush(log)
    end
    return out
end

run_validation(db, intervals::AbstractVector{DateTime}; kwargs...) =
    run_validation(db, DataFrame(; interval = collect(intervals)); kwargs...)

"""
    complementary_slackness_table(db, intervals; stratum = "month", kwargs...) -> DataFrame

Runs [`read_complementary_slackness`](@ref) over `intervals` and returns its result in the tidy
layout of [`run_validation`](@ref). It reads only published data, so it covers a whole month
cheaply. Families: `cs_violation_mw` (`gap` is the MW outside the price-implied bracket, `published`
the cleared MW) and `cs_units_violating` (`gap` is the unit count), one row per region and interval.

# Arguments
- `db`: an `AEMDB` connection.
- `intervals`: a `StepRange{DateTime}` of dispatch intervals.
- `stratum`: the label written to the `stratum` column.
- `kwargs...`: passed to [`read_complementary_slackness`](@ref).

# Returns
A `DataFrame` with the columns of [`run_validation`](@ref); `ours` is `missing`.
"""
function complementary_slackness_table(db, intervals::StepRange{DateTime}; stratum::AbstractString = "month", kwargs...)
    cs = read_complementary_slackness(db, intervals; kwargs...)
    rows = NamedTuple[]
    for r in eachrow(cs)
        push!(
            rows,
            (; interval = r.SETTLEMENTDATE, stratum = String(stratum), metric_family = "cs_violation_mw", key = r.REGIONID, ours = missing, published = r.cleared_mw, gap = r.violation_mw),
            (; interval = r.SETTLEMENTDATE, stratum = String(stratum), metric_family = "cs_units_violating", key = r.REGIONID, ours = missing, published = Float64(r.n_units), gap = Float64(r.n_violating)),
        )
    end
    return append!(copy(_EMPTY_VALIDATION), DataFrame(rows); promote = true)
end

"""
    validation_summary(table; tolerances = VALIDATION_TOLERANCES) -> DataFrame

Summarises a [`run_validation`](@ref) table as distributions of `abs(gap)` per metric family and
stratum, plus an `overall` row per family.

# Arguments
- `table`: the tidy table.
- `tolerances`: `metric_family => tolerance`; `n_above` counts rows whose `abs(gap)` exceeds it.

# Returns
A `DataFrame` with `stratum`, `metric_family`, `n` (rows with a gap), `n_missing` (rows without a
solved value), `median`, `p90`, `max` and `n_above`. Failures are one row per stratum with
their count in `n`.
"""
function validation_summary(table::DataFrame; tolerances = VALIDATION_TOLERANCES)
    rows = NamedTuple[]
    summarise(stratum, family, sub) = begin
        gaps = abs.(collect(skipmissing(sub.gap)))
        tol = get(tolerances, family, NaN)
        push!(
            rows, (;
                stratum, metric_family = family, n = length(gaps), n_missing = count(ismissing, sub.gap),
                median = isempty(gaps) ? missing : median(gaps), p90 = isempty(gaps) ? missing : quantile(gaps, 0.9),
                max = isempty(gaps) ? missing : maximum(gaps), n_above = count(>(tol), gaps),
            ),
        )
    end
    for (key, sub) in pairs(groupby(table, [:stratum, :metric_family]))
        summarise(key.stratum, key.metric_family, sub)
    end
    for (key, sub) in pairs(groupby(table, :metric_family))
        summarise("overall", key.metric_family, sub)
    end
    return sort!(DataFrame(rows), [:metric_family, :stratum])
end
