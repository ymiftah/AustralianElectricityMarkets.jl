# Replays consecutive intervals with replicate_range and with one replicate_interval each, and
# compares the solved prices, dispatch, flows, losses and objectives. From the repository root:
#
#     julia --project=AustralianElectricityMarketsSimulations/test \
#         AustralianElectricityMarketsSimulations/scripts/range_vs_interval.jl \
#         [start=2026-01-01T04:05:00] [n=12] [out_dir=/run/media/simba/Store/aem_validation/m8_accept] \
#         [hive=~/.nemdb_cache]
#
# The intervals must lie inside one trading day, and the cache must hold the interval after the last.

using AustralianElectricityMarkets
using AustralianElectricityMarketsSimulations
using DataFrames
using Dates
using HiGHS
import PowerSimulations as PSI
using Printf

const AEM_RVI = AustralianElectricityMarketsSimulations
const RANGE_TOLERANCES = (price = 0.01, mw = 0.1, objective_rtol = 1.0e-7)
const _RVI_OPTIMIZER = PSI.JuMP.optimizer_with_attributes(
    HiGHS.Optimizer, "mip_rel_gap" => 0.0, "mip_abs_gap" => 1.0e-10, "output_flag" => false,
)

# The compared tables: output name, the `comparison` table it reads, its key and its solved value column.
const _RVI_TABLES = (
    (table = "price", source = :prices, key = r -> string(r.REGIONID), value = :ROP_solved, tolerance = RANGE_TOLERANCES.price),
    (
        table = "fcas_price", source = :fcas_prices, key = r -> "$(r.REGIONID)/$(r.BIDTYPE)", value = :ROP_solved,
        tolerance = RANGE_TOLERANCES.price,
    ),
    (table = "dispatch", source = :dispatch, key = r -> string(r.DUID), value = :TOTALCLEARED_solved, tolerance = RANGE_TOLERANCES.mw),
    (table = "flow", source = :interconnectors, key = r -> string(r.INTERCONNECTORID), value = :MWFLOW_solved, tolerance = RANGE_TOLERANCES.mw),
    (table = "loss", source = :interconnectors, key = r -> string(r.INTERCONNECTORID), value = :MWLOSSES_solved, tolerance = RANGE_TOLERANCES.mw),
)

# `key => value` of one comparison table, `missing` where the table has no solved value; throws on a repeated key.
function _rvi_values(df::AbstractDataFrame, spec)
    values = Dict{String, Union{Missing, Float64}}()
    for r in eachrow(df)
        key = spec.key(r)
        haskey(values, key) && error("_rvi_values: key $key appears twice in the $(spec.table) table.")
        values[key] = r[spec.value]
    end
    return values
end

"""
    run_range_vs_interval(db, steps; optimizer = _RVI_OPTIMIZER, output_dir = mktempdir()) -> NamedTuple

Solves `steps` with one [`replicate_range`](@ref) and with one [`replicate_interval`](@ref) per interval.
The range must be one trading-day chunk.

# Arguments
- `db`: an `AEMDB` connection holding the data for `steps` and the interval after the last.
- `steps`: consecutive 5-minute intervals within one trading day.
- `optimizer`: the JuMP optimizer for both replays.
- `output_dir`: the directory of the range's chunk folder.

# Returns
A `NamedTuple` of `range` (the [`replicate_range`](@ref) output), `intervals` (a `Dict` from each
`SETTLEMENTDATE` to its `replicate_interval` `comparison`), `interval_objectives` (a `Dict` from each
`SETTLEMENTDATE` to its objective value) and `timing` (a `DataFrame` of `run` and `seconds`).
"""
function run_range_vs_interval(db, steps::StepRange{DateTime}; optimizer = _RVI_OPTIMIZER, output_dir = mktempdir())
    length(AEM_RVI._range_chunks(steps, :trading_day)) == 1 ||
        throw(ArgumentError("run_range_vs_interval: steps cross a trading day or 1 July."))
    timing = DataFrame(run = String[], seconds = Float64[])
    range = nothing
    range_s = @elapsed range = replicate_range(db, first(steps), last(steps); optimizer = optimizer, output_dir = joinpath(output_dir, "range"))
    push!(timing, ("range", range_s))
    intervals = Dict{DateTime, NamedTuple}()
    interval_objectives = Dict{DateTime, Float64}()
    for t in steps
        local solved
        seconds = @elapsed solved = replicate_interval(db, t; optimizer = optimizer)
        interval_objectives[t] = only(PSI.read_optimizer_stats(solved.results).objective_value)
        intervals[t] = (; comparison = solved.comparison)
        push!(timing, ("interval_$t", seconds))
    end
    return (; range, intervals, interval_objectives, timing)
end

"""
    range_vs_interval_long(range_out, intervals) -> DataFrame

One row per interval, table and key present in either replay: the range's and the interval's solved
values, their difference `gap` (`missing` if either is missing), the table's tolerance, whether the
key or its value is on one side only (`one_sided`) and whether the two agree within the tolerance
(`within`; two missing values agree, and a one-sided row never does).
"""
function range_vs_interval_long(range_out, intervals::AbstractDict{DateTime, <:NamedTuple})
    rows = DataFrame(
        SETTLEMENTDATE = DateTime[], table = String[], key = String[], range = Union{Missing, Float64}[],
        interval = Union{Missing, Float64}[], gap = Union{Missing, Float64}[], tolerance = Float64[],
        one_sided = Bool[], within = Bool[],
    )
    for t in sort!(collect(keys(intervals)))
        for spec in _RVI_TABLES
            range_side = _rvi_values(filter(:SETTLEMENTDATE => ==(t), getproperty(range_out.comparison, spec.source)), spec)
            interval_side = _rvi_values(getproperty(intervals[t].comparison, spec.source), spec)
            for key in sort!(collect(union(keys(range_side), keys(interval_side))))
                r = get(range_side, key, missing)
                i = get(interval_side, key, missing)
                gap = ismissing(r) || ismissing(i) ? missing : r - i
                one_sided = !haskey(range_side, key) || !haskey(interval_side, key) || ismissing(r) ⊻ ismissing(i)
                within = !one_sided && ((ismissing(r) && ismissing(i)) || (!ismissing(gap) && abs(gap) <= spec.tolerance))
                push!(rows, (t, spec.table, key, r, i, gap, spec.tolerance, one_sided, within))
            end
        end
    end
    return rows
end

"""
    range_vs_interval_summary(long, range_out, interval_objectives) -> DataFrame

One row per interval: the two objectives and their relative gap, the largest absolute gap of each
table, the number of rows outside tolerance and of one-sided rows, and `status`: `MATCH`
when every row is within tolerance and the objectives agree, `ALT_OPTIMUM` when some rows differ
but the objectives agree and no row is one-sided, and `FAIL` otherwise.
"""
function range_vs_interval_summary(long::DataFrame, range_out, interval_objectives::AbstractDict{DateTime, Float64})
    out = DataFrame(
        SETTLEMENTDATE = DateTime[], objective_range = Float64[], objective_interval = Float64[], objective_rel_gap = Float64[],
        max_price_gap = Float64[], max_fcas_price_gap = Float64[], max_dispatch_gap = Float64[], max_flow_gap = Float64[],
        max_loss_gap = Float64[], n_rows = Int[], n_outside = Int[], n_one_sided_missing = Int[], status = String[],
    )
    for t in sort!(collect(keys(interval_objectives)))
        at_t = filter(:SETTLEMENTDATE => ==(t), long)
        objective_range = only(filter(:SETTLEMENTDATE => ==(t), range_out.solver_stats).objective_value)
        objective_interval = interval_objectives[t]
        rel = abs(objective_range - objective_interval) / max(1.0, abs(objective_interval))
        max_gap(table) = begin
            gaps = [abs(g) for g in at_t.gap[at_t.table .== table] if !ismissing(g)]
            isempty(gaps) ? 0.0 : maximum(gaps)
        end
        n_outside = count(!, at_t.within)
        n_one_sided = count(at_t.one_sided)
        status = if n_outside == 0 && rel <= RANGE_TOLERANCES.objective_rtol
            "MATCH"
        elseif n_outside > 0 && n_one_sided == 0 && rel <= RANGE_TOLERANCES.objective_rtol
            "ALT_OPTIMUM"
        else
            "FAIL"
        end
        push!(
            out, (
                t, objective_range, objective_interval, rel, max_gap("price"), max_gap("fcas_price"),
                max_gap("dispatch"), max_gap("flow"), max_gap("loss"), nrow(at_t), n_outside, n_one_sided, status,
            ),
        )
    end
    return out
end

# CSV cell: empty for `missing`, ISO text for dates, `repr` for floats (no value contains a comma).
_rvi_cell(v) = ismissing(v) ? "" : v isa DateTime ? string(v) : v isa AbstractFloat ? repr(v) : string(v)

function _write_rvi_csv(path::AbstractString, df::DataFrame)
    open(path, "w") do io
        println(io, join(names(df), ","))
        for r in eachrow(df)
            println(io, join((_rvi_cell(r[c]) for c in names(df)), ","))
        end
    end
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    start = DateTime(length(ARGS) >= 1 ? ARGS[1] : "2026-01-01T04:05:00")
    n = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 12
    out_dir = length(ARGS) >= 3 ? ARGS[3] : "/run/media/simba/Store/aem_validation/m8_accept"
    hive = length(ARGS) >= 4 ? ARGS[4] : joinpath(homedir(), ".nemdb_cache")
    db = aem_connect(HiveConfiguration(hive_location = hive))
    steps = start:Minute(5):(start + Minute(5) * (n - 1))
    mkpath(out_dir)
    out = run_range_vs_interval(db, steps; output_dir = out_dir)
    long = range_vs_interval_long(out.range, out.intervals)
    summary = range_vs_interval_summary(long, out.range, out.interval_objectives)
    _write_rvi_csv(joinpath(out_dir, "range_vs_interval_long.csv"), long)
    _write_rvi_csv(joinpath(out_dir, "range_vs_interval_summary.csv"), summary)
    _write_rvi_csv(joinpath(out_dir, "timing.csv"), out.timing)

    show(stdout, summary; allrows = true, allcols = true)
    println()
    for spec in _RVI_TABLES
        rows = filter(r -> r.table == spec.table && !ismissing(r.gap), long)
        isempty(rows) && continue
        println("WORST $(spec.table)")
        show(stdout, first(sort(rows, :gap, by = abs, rev = true), 5); allrows = true, allcols = true)
        println()
    end
    @printf("RANGE seconds=%s INTERVALS seconds=%s\n", repr(out.timing.seconds[1]), repr(sum(out.timing.seconds[2:end])))
    counts = Dict(s => count(==(s), summary.status) for s in ("MATCH", "ALT_OPTIMUM", "FAIL"))
    verdict = counts["FAIL"] == 0 ? "PASS" : "FAIL"
    println("ACCEPTANCE $verdict match=$(counts["MATCH"]) alt_optimum=$(counts["ALT_OPTIMUM"]) fail=$(counts["FAIL"])")
end
