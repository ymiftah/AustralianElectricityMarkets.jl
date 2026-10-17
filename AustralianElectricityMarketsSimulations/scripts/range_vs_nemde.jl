# Compares the stored results of one replicate_range run with NEMDE's published dispatch, without
# re-solving. The PSI store under <sim_out_dir>/sim is reopened, the system is rebuilt for the same
# steps with `replication_system` (no model build) and the solved frames are compared with the
# published outcomes. From the repository root:
#
#     julia --project=AustralianElectricityMarketsSimulations/test --threads=1 \
#         AustralianElectricityMarketsSimulations/scripts/range_vs_nemde.jl \
#         sim_out_dir [start=2026-01-01T04:05:00] [n_steps=288] [hive=~/.nemdb_cache] [out_dir]
#
# Writes comparison_long.csv, summary_metrics.csv and summary.md to `out_dir` and prints the
# headline table. Gaps are AEMSim minus NEMDE's published value.

using AustralianElectricityMarkets
using AustralianElectricityMarketsSimulations
using DataFrames
using Dates
using Statistics
import PowerSimulations as PSI

const AEM_COMPARE = AustralianElectricityMarketsSimulations

const COMPARE_GROUPS = ["regional_rop", "fcas_rop", "interconnector_flow", "interconnector_loss", "dispatch_mw"]
const COMPARE_TOLERANCES = Dict(
    "regional_rop" => 1.0, "fcas_rop" => 1.0, "interconnector_flow" => 5.0,
    "interconnector_loss" => 3.0, "dispatch_mw" => 1.0,
)

# `REGION/SERVICE` key of an FCAS row; the BidType enum may print as `BidType.SERVICE = n`.
function _fcas_key(region, bidtype)
    s = string(bidtype)
    m = match(r"([A-Z0-9]+)(?: = \d+)?$", s)
    return "$(region)/$(isnothing(m) ? s : m.captures[1])"
end

# One row per published value of the range: solved, published and gap (solved minus published).
function _long_comparison(comparison)
    interval, metric, key = DateTime[], String[], String[]
    solved, published, gap = Union{Missing, Float64}[], Float64[], Union{Missing, Float64}[]
    function add!(group, df, keyfun, pubcol, solcol)
        for r in eachrow(df)
            ismissing(r[pubcol]) && continue
            s = ismissing(r[solcol]) ? missing : Float64(r[solcol])
            p = Float64(r[pubcol])
            push!(interval, r.SETTLEMENTDATE)
            push!(metric, group)
            push!(key, keyfun(r))
            push!(solved, s)
            push!(published, p)
            push!(gap, ismissing(s) ? missing : s - p)
        end
        return
    end
    add!("regional_rop", comparison.prices, r -> string(r.REGIONID), :ROP_published, :ROP_solved)
    add!("fcas_rop", comparison.fcas_prices, r -> _fcas_key(r.REGIONID, r.BIDTYPE), :ROP_published, :ROP_solved)
    add!("interconnector_flow", comparison.interconnectors, r -> string(r.INTERCONNECTORID), :MWFLOW_published, :MWFLOW_solved)
    add!("interconnector_loss", comparison.interconnectors, r -> string(r.INTERCONNECTORID), :MWLOSSES_published, :MWLOSSES_solved)
    add!("dispatch_mw", comparison.dispatch, r -> string(r.DUID), :TOTALCLEARED_published, :TOTALCLEARED_solved)
    isempty(interval) && error("range_vs_nemde: no published rows for the range.")
    rank = Dict(g => i for (i, g) in enumerate(COMPARE_GROUPS))
    perm = sortperm(eachindex(interval); by = i -> (rank[metric[i]], interval[i], key[i]))
    return DataFrame(
        interval = interval[perm], metric = metric[perm], key = key[perm],
        solved = solved[perm], published = published[perm], gap = gap[perm],
    )
end

# Absolute gaps of `group` (non-missing), optionally restricted to keys passing `keep`.
function _abs_gaps(long::DataFrame, group::AbstractString; keep = _ -> true)
    idx = [i for i in eachindex(long.gap) if long.metric[i] == group && !ismissing(long.gap[i]) && keep(long.key[i])]
    return Float64[abs(long.gap[i]) for i in idx]
end

_stat(f, xs) = isempty(xs) ? missing : f(xs)

# Headline metrics of `long` as absolute gaps to NEMDE, the same definitions as the perf_horizon1 summary.
function _summary(long::DataFrame)
    out = Tuple{String, Any}[]
    add!(name, v) = push!(out, (name, v))
    total(g) = count(==(g), long.metric)
    tol = COMPARE_TOLERANCES
    not_tas1 = k -> !startswith(k, "TAS1/")
    gaps(g; keep = _ -> true) = _abs_gaps(long, g; keep)

    rop = gaps("regional_rop")
    add!("regional_rop_rows", total("regional_rop"))
    add!("regional_rop_mean_gap", _stat(mean, rop))
    add!("regional_rop_median_gap", _stat(median, rop))
    add!("regional_rop_p90_gap", _stat(x -> quantile(x, 0.9), rop))
    add!("regional_rop_max_gap", _stat(maximum, rop))
    add!("regional_rop_rows_within_tolerance", count(<=(tol["regional_rop"]), rop))
    add!("fcas_rop_rows", total("fcas_rop"))
    add!("fcas_rop_mean_gap_excl_tas1", _stat(mean, gaps("fcas_rop"; keep = not_tas1)))
    add!("fcas_rop_max_gap_excl_tas1", _stat(maximum, gaps("fcas_rop"; keep = not_tas1)))
    add!("fcas_rop_mean_gap_incl_tas1", _stat(mean, gaps("fcas_rop")))
    add!("fcas_rop_max_gap_incl_tas1", _stat(maximum, gaps("fcas_rop")))
    add!("fcas_rop_rows_within_tolerance", count(<=(tol["fcas_rop"]), gaps("fcas_rop")))
    flow = gaps("interconnector_flow")
    add!("interconnector_flow_rows", total("interconnector_flow"))
    add!("interconnector_flow_mean_gap", _stat(mean, flow))
    add!("interconnector_flow_median_gap", _stat(median, flow))
    add!("interconnector_flow_max_gap", _stat(maximum, flow))
    add!("interconnector_flow_share_within_tolerance", _stat(x -> count(<=(tol["interconnector_flow"]), x) / length(x), flow))
    loss = gaps("interconnector_loss")
    add!("interconnector_loss_mean_gap", _stat(mean, loss))
    add!("interconnector_loss_max_gap", _stat(maximum, loss))
    add!("interconnector_loss_share_within_tolerance", _stat(x -> count(<=(tol["interconnector_loss"]), x) / length(x), loss))
    mw = gaps("dispatch_mw")
    add!("dispatch_mw_rows", total("dispatch_mw"))
    add!("dispatch_mw_share_within_tolerance", _stat(x -> count(<=(tol["dispatch_mw"]), x) / length(x), mw))
    add!("dispatch_mw_rows_beyond_tolerance", count(>(tol["dispatch_mw"]), mw))
    add!("dispatch_mw_sum_of_gaps", sum(mw))
    mw_rows = [i for i in eachindex(long.gap) if long.metric[i] == "dispatch_mw"]
    add!("dispatch_mw_missing_share", isempty(mw_rows) ? missing : count(i -> ismissing(long.solved[i]), mw_rows) / length(mw_rows))
    return DataFrame(metric = first.(out), aemsim = Any[last(p) for p in out])
end

# Rows per metric group over tolerance, and the intervals that contain at least one of them.
function _over_tolerance(long::DataFrame, intervals::Int)
    rows = NamedTuple[]
    for g in COMPARE_GROUPS
        idx = [i for i in eachindex(long.gap) if long.metric[i] == g && !ismissing(long.gap[i])]
        over = [i for i in idx if abs(long.gap[i]) > COMPARE_TOLERANCES[g]]
        push!(
            rows, (;
                metric = g, tolerance = COMPARE_TOLERANCES[g], rows = length(idx), rows_over = length(over),
                share_over = isempty(idx) ? missing : length(over) / length(idx),
                intervals_over = length(unique(long.interval[over])), intervals = intervals,
            ),
        )
    end
    return DataFrame(rows)
end

# Regional ROP by hour (the hour the 5-minute interval starts in): signed and absolute mean gaps.
function _rop_by_hour(long::DataFrame)
    idx = [i for i in eachindex(long.gap) if long.metric[i] == "regional_rop" && !ismissing(long.gap[i])]
    hours = [floor(long.interval[i] - Minute(5), Hour) for i in idx]
    rows = NamedTuple[]
    for h in sort(unique(hours))
        g = [long.gap[idx[j]] for j in eachindex(idx) if hours[j] == h]
        push!(
            rows, (;
                hour = Dates.format(h, "yyyy-mm-dd HH:00"), rows = length(g), mean_gap = mean(g),
                mean_abs_gap = mean(abs.(g)), max_abs_gap = maximum(abs.(g)),
                share_within_tolerance = count(x -> abs(x) <= COMPARE_TOLERANCES["regional_rop"], g) / length(g),
            ),
        )
    end
    return DataFrame(rows)
end

# The `n` rows with the largest absolute gap per metric group.
function _worst(long::DataFrame; n::Integer = 10)
    rows = NamedTuple[]
    for g in COMPARE_GROUPS
        idx = [i for i in eachindex(long.gap) if long.metric[i] == g && !ismissing(long.gap[i])]
        for i in first(sort(idx; by = i -> -abs(long.gap[i])), min(n, length(idx)))
            push!(rows, (; metric = g, interval = long.interval[i], key = long.key[i], published = long.published[i], solved = long.solved[i], gap = long.gap[i]))
        end
    end
    return DataFrame(rows)
end

_fmt(x::Missing) = "n/a"
_fmt(x::Integer) = string(x)
_fmt(x::AbstractFloat) = isinteger(x) && abs(x) < 1.0e9 ? string(Int(x)) : string(round(x; sigdigits = 4))
_fmt(x::DateTime) = Dates.format(x, "yyyy-mm-dd HH:MM")
_fmt(x) = string(x)

function _md_table(df::DataFrame)
    head = "| " * join(names(df), " | ") * " |"
    rule = "| " * join(("---" for _ in names(df)), " | ") * " |"
    body = ["| " * join((_fmt(x) for x in r), " | ") * " |" for r in eachrow(df)]
    return join([head, rule, body...], "\n")
end

# CSV without quoting: keys and values carry no commas. Missing values are empty fields.
_csv(x::Missing) = ""
_csv(x::DateTime) = Dates.format(x, "yyyy-mm-ddTHH:MM:SS")
_csv(x::AbstractFloat) = repr(Float64(x))
_csv(x) = string(x)

function _write_csv(path::AbstractString, df::DataFrame)
    open(path, "w") do io
        println(io, join(names(df), ","))
        for r in eachrow(df)
            println(io, join((_csv(x) for x in r), ","))
        end
    end
    return
end

function _write_summary(path, long, headline, over, rop_hours, worst; sim_out_dir, steps, hive)
    open(path, "w") do io
        println(io, "# Stock-simulation range vs NEMDE\n")
        println(io, "- Stored run: `$sim_out_dir/sim` (reopened, not re-solved)")
        println(io, "- Hive: `$hive`")
        println(io, "- Intervals: $(length(steps)), $(first(steps)) to $(last(steps))")
        println(io, "- Gaps are AEMSim minus NEMDE's published value; the headline gives absolute gaps.")
        println(io, "- Tolerances: " * join(("$g $(COMPARE_TOLERANCES[g])" for g in COMPARE_GROUPS), ", ") * "\n")
        println(io, "## Headline metrics (AEMSim)\n")
        println(io, _md_table(headline), "\n")
        println(io, "## Intervals over tolerance\n")
        println(io, _md_table(over), "\n")
        println(io, "## Regional ROP per hour (interval start hour)\n")
        println(io, _md_table(rop_hours), "\n")
        println(io, "## Worst 10 rows per metric (one row is one interval and key)\n")
        println(io, _md_table(worst))
    end
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) >= 1 || error("usage: range_vs_nemde.jl sim_out_dir [start] [n_steps] [hive] [out_dir]")
    sim_out_dir = ARGS[1]
    start = DateTime(length(ARGS) >= 2 ? ARGS[2] : "2026-01-01T04:05:00")
    n_steps = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 288
    hive = length(ARGS) >= 4 ? ARGS[4] : joinpath(homedir(), ".nemdb_cache")
    out_dir = length(ARGS) >= 5 ? ARGS[5] :
        joinpath("/run/media/simba/Store/aem_validation/stock_sim/nemde_compare", basename(sim_out_dir))

    db = aem_connect(HiveConfiguration(hive_location = hive))
    steps = start:Minute(5):(start + Minute(5) * (n_steps - 1))
    sys = replication_system(db, first(steps):Minute(5):(last(steps) + Minute(5)); time_series_in_memory = true)

    # Reopen the stored decision problem; this reads the store and never builds or solves a model.
    results = PSI.get_decision_problem_results(PSI.SimulationResults(joinpath(sim_out_dir, "sim")), "dispatch")
    frames = AEM_COMPARE._solved_frames(results, sys; losses = true)
    AEM_COMPARE._check_prices_finite(frames.balance_duals)
    comparison = AEM_COMPARE._compare_range_to_published(db, sys, frames, steps, 0)

    long = _long_comparison(comparison)
    headline = _summary(long)
    over = _over_tolerance(long, length(steps))
    rop_hours = _rop_by_hour(long)
    worst = _worst(long)

    mkpath(out_dir)
    _write_csv(joinpath(out_dir, "comparison_long.csv"), long)
    _write_csv(joinpath(out_dir, "summary_metrics.csv"), headline)
    _write_summary(
        joinpath(out_dir, "summary.md"), long, headline, over, rop_hours, worst;
        sim_out_dir, steps, hive,
    )
    println(_md_table(headline))
    println(_md_table(over))
    println("WROTE $out_dir")
end
