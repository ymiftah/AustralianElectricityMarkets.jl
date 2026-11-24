# Replicates nempy's 1000-interval benchmark (benchmarking/README.md) end to end in one script:
# populate the cache, solve each interval alone against AEMO's observed state, compare with the
# published NEMDE outcomes, and write analysis-ready artifacts for runtime and NEMDE-difference studies.
#
#   julia -O1 --project=AustralianElectricityMarketsSimulations/test scripts/nempy_benchmark.jl --help
using Chain
using DataFrames
using Dates
using DuckDB
using Printf
using Random
using TOML

const ROOT = dirname(@__DIR__)
const INTERVALS_FILE = joinpath(ROOT, "benchmarking", "nempy_2024h2_intervals.csv")
const NEMPY = (mean = 0.13818, median = 0.0, p5 = -0.13336, p95 = 0.01353)
const TEST_ENV = joinpath(ROOT, "AustralianElectricityMarketsSimulations", "test")

function usage()
    println(
        """
        nempy-style benchmark on a year of NEM data: N intervals drawn along the system-demand load
        duration curve (equal-count strata, one random interval each), each solved independently, in parallel shards.

        julia -O1 --project=AustralianElectricityMarketsSimulations/test scripts/nempy_benchmark.jl [options]

          --output FOLDER       Run folder (default ~/aem_validation/ldc-benchmark-<timestamp>)
          --year Y              Calendar year to sample (2025)
          --number N            Intervals to draw (1000)
          --seed INTEGER        Seed of the draw (1)
          --workers N           Parallel batch_run.jl processes, each a shard of whole trading days (6)
          --hours NUMBER        Per-shard wall time after which no new trading day starts (24)
          --hive FOLDER         Local market cache (~/.nemdb_cache)
          --populate B          Download the year's missing tables into the cache first (false)
          --populate-only B     Populate, then stop (false)
          --solver-threads N    HiGHS threads per worker (1)
          --resample B          Replace the intervals of an existing --output run that did not complete with new draws
                                from the same strata (never from their trading days), solve them, and refresh the analysis (false)
          --skip-run B          Only (re)build the analysis of an existing --output folder (false)

        Artifacts, under <output>/: load_duration_curve.csv (every interval ranked by demand, with stratum),
        ldc_sample.csv, shard_k/<day>/ (raw comparison, solver, violation and timer files), simulation_statistics/,
        and analysis/: price_errors.csv, interval_runtimes.csv (both with system demand, LDC rank and stratum),
        fcas_errors.csv, dispatch_errors.csv, interconnector_errors.csv, constraint_violations.csv,
        nempy_comparison.md and manifest.toml.
        """
    )
    return
end

function parse_args(args)
    options = Dict(
        "output" => joinpath(homedir(), "aem_validation", "ldc-benchmark-" * Dates.format(now(), "yyyymmddTHHMMSS")),
        "number" => "1000", "seed" => "1", "year" => "2025", "workers" => "6", "populate-only" => "false", "resample" => "false", "hours" => "24", "hive" => joinpath(homedir(), ".nemdb_cache"),
        "populate" => "false", "solver-threads" => "1", "skip-run" => "false",
    )
    i = 1
    while i <= length(args)
        key = replace(args[i], r"^--" => "")
        haskey(options, key) || throw(ArgumentError("unknown option $(args[i])"))
        i < length(args) || throw(ArgumentError("missing value for $(args[i])"))
        options[key] = args[i + 1]
        i += 2
    end
    return options
end

# Populates the NEMDE tables for `year` in a subprocess on the docs environment, which holds the Data package
# the test environment lacks; DISPATCH_FCAS_REQ_CONSTRAINT only exists from 2025-06.
function populate_cache(year, tables = nothing)
    list = tables === nothing ? "table_requirements(NEMDEConfiguration())" : repr(tables)
    code = """
    using AustralianElectricityMarkets, AustralianElectricityMarketsData, Dates
    db = aem_connect()
    for table in $list
        first_day = table == :DISPATCH_FCAS_REQ_CONSTRAINT ? max(Date($year, 1, 1), Date(2025, 6, 1)) : Date($year, 1, 1)
        first_day > Date($year, 12, 31) && continue
        @info "populating" table
        AustralianElectricityMarketsData.populate(db, table, first_day, Date($year, 12, 31))
    end
    """
    run(`julia --project=$(joinpath(ROOT, "docs")) -e $code`)
    return
end

_trading_day(t::DateTime) = Date(t - Hour(4) - Minute(5))

# Stratified draw along the system-demand load duration curve: the intervals of `year` ranked by total
# demand (all regions, INTERVENTION = 0) are cut into `n` equal-count strata, one random interval per stratum.
function ldc_sample(options)
    year, n, hive = parse(Int, options["year"]), parse(Int, options["number"]), options["hive"]
    db = DuckDB.DB()
    ldc = DataFrame(
        DuckDB.execute(
            db,
            "SELECT SETTLEMENTDATE AS interval, SUM(TOTALDEMAND) AS system_demand_mw FROM " *
                "read_parquet('$hive/DISPATCHREGIONSUM/*/*.parquet', hive_partitioning = true, union_by_name = true) " *
                "WHERE INTERVENTION = 0 AND SETTLEMENTDATE >= TIMESTAMP '$year-01-01 04:05:00' " *
                "AND SETTLEMENTDATE <= TIMESTAMP '$year-12-31 23:55:00' " *
                "GROUP BY 1 HAVING COUNT(DISTINCT REGIONID) = 5",
        )
    )
    DBInterface.close!(db)
    size(ldc, 1) >= n || error("only $(size(ldc, 1)) complete intervals cached for $year; populate DISPATCHREGIONSUM first")
    sort!(ldc, :system_demand_mw; rev = true)
    ldc.ldc_rank = 1:size(ldc, 1)
    edges = round.(Int, range(0, size(ldc, 1); length = n + 1))
    rng = Xoshiro(parse(Int, options["seed"]))
    picks = [rand(rng, (edges[k] + 1):edges[k + 1]) for k in 1:n]
    ldc.stratum = zeros(Int, size(ldc, 1))
    for k in 1:n
        ldc.stratum[(edges[k] + 1):edges[k + 1]] .= k
    end
    return ldc, sort(ldc[picks, :], :interval)
end

function write_table(path, df)
    open(path, "w") do io
        println(io, join(names(df), ','))
        foreach(r -> println(io, join((ismissing(x) ? "" : x for x in r), ',')), eachrow(df))
    end
    return path
end

# Splits the sampled intervals into `workers` shards of whole trading days, balanced by interval count.
function shard_intervals(sample, workers)
    by_day = Dict{Date, Vector{DateTime}}()
    for t in sample.interval
        push!(get!(by_day, _trading_day(t), DateTime[]), t)
    end
    shards = [DateTime[] for _ in 1:workers]
    for (_, ts) in sort(collect(by_day); by = x -> -length(x[2]))
        append!(shards[argmin(length.(shards))], ts)
    end
    return [sort(s) for s in shards]
end

function completed_intervals(output)
    done = Set{DateTime}()
    for f in glob_files(output, "chunks.csv")
        df = DataFrame(DuckDB.execute(DuckDB.DB(), "SELECT start FROM read_csv('$f', header = true)"))
        union!(done, df.start)
    end
    return done
end

function glob_files(output, name)
    return [
        joinpath(output, s, d, name) for s in readdir(output) if startswith(s, "shard_") && isdir(joinpath(output, s))
            for d in readdir(joinpath(output, s)) if isfile(joinpath(output, s, d, name))
    ]
end

# Draws a replacement for each sampled interval that did not complete: same stratum, not in the sample, and not
# on a trading day that lost an interval (those days fail on the same source gap).
function resample_missing(options)
    output = options["output"]
    ldc = DataFrame(DuckDB.execute(DuckDB.DB(), "SELECT * FROM read_csv('$(joinpath(output, "load_duration_curve.csv"))', header = true)"))
    sample = DataFrame(DuckDB.execute(DuckDB.DB(), "SELECT * FROM read_csv('$(joinpath(output, "ldc_sample.csv"))', header = true)"))
    missing_rows = sample[.!in.(sample.interval, Ref(completed_intervals(output))), :]
    isempty(missing_rows) && return nothing
    bad_days = Set(_trading_day.(missing_rows.interval))
    taken = Set(sample.interval)
    rng = Xoshiro(parse(Int, options["seed"]) + 1)
    rows = NamedTuple[]
    for r in eachrow(missing_rows)
        pool = ldc[(ldc.stratum .== r.stratum) .& .!in.(ldc.interval, Ref(taken)) .& .!in.(_trading_day.(ldc.interval), Ref(bad_days)), :]
        isempty(pool) && error("no replacement left in stratum $(r.stratum)")
        pick = pool[rand(rng, 1:size(pool, 1)), :]
        push!(taken, pick.interval)
        push!(rows, (interval = pick.interval, system_demand_mw = pick.system_demand_mw, ldc_rank = pick.ldc_rank, stratum = pick.stratum, replaces = r.interval))
    end
    picks = DataFrame(rows)
    write_table(joinpath(output, "ldc_resample.csv"), select(picks, :interval, :system_demand_mw, :ldc_rank, :stratum, :replaces))
    return select(picks, :interval, :system_demand_mw, :ldc_rank, :stratum)
end

function run_batch(options, sample; first_shard = 1)
    output, workers = options["output"], parse(Int, options["workers"])
    mkpath(output)
    shards = shard_intervals(sample, workers)
    procs = Base.Process[]
    for (j, ts) in enumerate(shards)
        isempty(ts) && continue
        k = first_shard + j - 1
        file = joinpath(output, "intervals_shard_$k.csv")
        write(file, join(vcat("interval", Dates.format.(ts, "yyyy-mm-ddTHH:MM:SS")), "\n") * "\n")
        cmd = `julia -O1 --project=$TEST_ENV $(joinpath(ROOT, "scripts", "batch_run.jl"))
            --intervals-file $file --hours $(options["hours"]) --hive $(options["hive"])
            --solver-threads $(options["solver-threads"]) --output $(joinpath(output, "shard_$k"))`
        push!(procs, run(pipeline(cmd; stdout = joinpath(output, "shard_$k.log"), stderr = stdout); wait = false))
    end
    foreach(wait, procs)
    folders = [joinpath(output, d) for d in sort(readdir(output)) if startswith(d, "shard_") && isdir(joinpath(output, d))]
    run(`julia --project=$TEST_ENV $(joinpath(ROOT, "scripts", "simulation_statistics.jl")) $folders --output $(joinpath(output, "simulation_statistics")) --hive $(options["hive"])`)
    return
end

# Reads one CSV kind from every trading-day folder, adding the folder's trading day.
function read_days(output, name)
    pattern = joinpath(output, "shard_*", "*", name)
    isempty(filter(isfile, [joinpath(output, s, d, name) for s in readdir(output) if startswith(s, "shard_") && isdir(joinpath(output, s)) for d in readdir(joinpath(output, s)) if isdir(joinpath(output, s, d))])) && return nothing
    db = DuckDB.DB()
    df = DataFrame(
        DuckDB.execute(
            db,
            "SELECT * , regexp_extract(filename, '([^/]+)/$name\$', 1) AS trading_day " *
                "FROM read_csv('$pattern', filename = true, union_by_name = true, header = true)",
        )
    )
    select!(df, Not(:filename))
    DBInterface.close!(db)
    return df
end

quantile_of(v, p) = (s = sort(v); return s[clamp(ceil(Int, p * length(s)), 1, length(s))])

function analyse(options)
    output = options["output"]
    analysis = joinpath(output, "analysis")
    mkpath(analysis)
    files = String[]
    write_csv(name, df) = (write_table(joinpath(analysis, name), df); push!(files, name))
    sample = DataFrame(DuckDB.execute(DuckDB.DB(), "SELECT * FROM read_csv('$(joinpath(output, "ldc_sample.csv"))', header = true)"))
    if isfile(joinpath(output, "ldc_resample.csv"))
        extra = DataFrame(DuckDB.execute(DuckDB.DB(), "SELECT * FROM read_csv('$(joinpath(output, "ldc_resample.csv"))', header = true)"))
        sample = vcat(filter(r -> !(r.interval in extra.replaces), sample), select(extra, Not(:replaces)))
        sort!(sample, :interval)
    end
    write_csv("ldc_sample.csv", sample)
    ldc_info = select(sample, :interval, :system_demand_mw, :ldc_rank, :stratum)

    prices = read_days(output, "comparison_prices.csv")
    if prices !== nothing
        @chain prices begin
            transform!([:ROP_solved, :ROP_published] => ((s, p) -> s .- p) => :error_rop, [:ROP_solved, :RRP_published] => ((s, p) -> s .- p) => :error_rrp)
            leftjoin!(_, rename(ldc_info, :interval => :SETTLEMENTDATE); on = :SETTLEMENTDATE)
            write_csv("price_errors.csv", _)
        end
        e = prices.error_rop
        e = e[isfinite.(e)]
        row(label, v) = @sprintf("| %s | %d | %.5f | %.5f | %.5f | %.5f | %.4f |", label, length(v), sum(v) / length(v), quantile_of(v, 0.5), quantile_of(v, 0.05), quantile_of(v, 0.95), maximum(abs, v))
        md = String[
            "# Benchmark against nempy", "",
            "Signed ROP error, solved minus published, in \$/MWh over the intervals this run completed.", "",
            "| Source | n | Mean | Median | p5 | p95 | Max abs |", "| --- | --- | --- | --- | --- | --- | --- |",
            @sprintf("| nempy (published, 1000 intervals) | - | %.5f | %.5f | %.5f | %.5f | - |", NEMPY.mean, NEMPY.median, NEMPY.p5, NEMPY.p95),
            row("AEMSim, all regions", e),
        ]
        for (region, sub) in pairs(groupby(prices, :REGIONID))
            v = sub.error_rop[isfinite.(sub.error_rop)]
            push!(md, row("AEMSim, $(region.REGIONID)", v))
        end
        push!(md, "", @sprintf("Intervals compared: %d; exact (|error| < 1e-3) share: %.1f%%.", length(unique(prices.SETTLEMENTDATE)), 100 * count(<(1.0e-3), abs.(e)) / length(e)))
        write(joinpath(analysis, "nempy_comparison.md"), join(md, "\n") * "\n")
        push!(files, "nempy_comparison.md")
    end

    chunks = read_days(output, "chunks.csv")
    stats = read_days(output, "solver_stats.csv")
    if chunks !== nothing
        rt = @chain chunks begin
            select(:trading_day, :start, :system_build_s, :simulation_build_s, :execute_s, :compare_s)
            rename(:start => :interval)
            leftjoin(ldc_info; on = :interval)
            transform(
                [:system_build_s, :simulation_build_s, :execute_s, :compare_s] => ((a, b, c, d) -> a .+ b .+ c .+ d) => :total_s
            )
        end
        if stats !== nothing
            rt = leftjoin(rt, select(stats, :SETTLEMENTDATE => :interval, :objective_value, :timed_solve_time, :timed_calculate_dual_variables, :termination_status); on = :interval)
        end
        write_csv("interval_runtimes.csv", rt)
    end
    for (name, out) in (("comparison_fcas_prices.csv", "fcas_errors.csv"), ("comparison_dispatch.csv", "dispatch_errors.csv"), ("comparison_interconnectors.csv", "interconnector_errors.csv"), ("constraint_violations.csv", "constraint_violations.csv"))
        df = read_days(output, name)
        df === nothing || write_csv(out, df)
    end

    manifest = Dict{String, Any}(
        "created" => string(now()), "julia" => string(VERSION), "options" => options,
        "intervals_file" => INTERVALS_FILE, "nempy" => Dict(string(k) => v for (k, v) in pairs(NEMPY)),
        "analysis_files" => files,
        "git_commit" => try
            readchomp(`git -C $ROOT rev-parse HEAD`)
        catch
            ""
        end,
        "raw_per_day_files" => ["comparison_*.csv", "solver_stats.csv", "chunks.csv", "constraint_violations.csv", "ramp_violations.csv", "skipped_constraints.csv", "provenance.toml", "package_source/"],
    )
    open(io -> TOML.print(io, manifest), joinpath(analysis, "manifest.toml"), "w")
    println("Analysis written to ", analysis)
    return
end

function main(args = ARGS)
    if "--help" in args
        usage()
        return
    end
    options = parse_args(args)
    if options["resample"] == "true"
        extra = resample_missing(options)
        if extra === nothing
            println("Every sampled interval completed.")
        else
            first_shard = 1 + length([d for d in readdir(options["output"]) if occursin(r"^shard_\d+$", d)])
            run_batch(options, extra; first_shard)
        end
    elseif options["skip-run"] != "true"
        ispath(joinpath(options["output"], "ldc_sample.csv")) && error("output folder already holds a run: $(options["output"])")
        year = parse(Int, options["year"])
        if options["populate"] == "true"
            populate_cache(year, [:DISPATCHREGIONSUM])
            populate_cache(year)
        end
        options["populate-only"] == "true" && return
        ldc, sample = ldc_sample(options)
        mkpath(options["output"])
        write_table(joinpath(options["output"], "load_duration_curve.csv"), ldc)
        write_table(joinpath(options["output"], "ldc_sample.csv"), sample)
        run_batch(options, sample)
    end
    analyse(options)
    return
end

abspath(PROGRAM_FILE) == (@__FILE__) && main()
