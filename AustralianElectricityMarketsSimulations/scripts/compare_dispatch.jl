# Compares dispatch results of the replica (AEMSim, `replicate_interval`) with NEMDE's published
# values and with stock nempy, for N random dispatch intervals or a whole date range. Local only;
# reads the hive cache and never writes to it. From the repository root:
#
#     julia --project=AustralianElectricityMarketsSimulations/test \
#         AustralianElectricityMarketsSimulations/scripts/compare_dispatch.jl --help
#
# The analysis lives in `src/replication/comparison.jl`; this script handles options, resource
# guards, the resumable AEMSim loop and the calls to the nempy harness in `scripts/nempy/`.

using AustralianElectricityMarkets
using AustralianElectricityMarketsData
using AustralianElectricityMarketsSimulations
using DataFrames
using Dates
using HiGHS
using PowerSimulations: optimizer_with_attributes

const AEMS = AustralianElectricityMarketsSimulations
const NEMPY_SCRIPTS = joinpath(@__DIR__, "nempy")
const STORE_ROOT = "/run/media/simba/Store/aem_validation"

const USAGE = """
Usage: julia --project=AustralianElectricityMarketsSimulations/test \\
           AustralianElectricityMarketsSimulations/scripts/compare_dispatch.jl [options]

Compares AEMSim (`replicate_interval`) with NEMDE's published values and with stock nempy.

Selection (dates are NEM market days, 04:05 to 04:00 the next calendar day)
  --n N               random mode: N distinct 5-minute intervals (default 100)
  --seed S            seed of the draw (default 1)
  --from D --to D     range of market days (default 2026-06-01 to 2026-06-30)
  --days K            random mode draws from K random market days to bound the NEMDE
                      downloads (about $(AEMS.NEMDE_DAY_ZIP_MB) MB per day); default min(N, 10)
  --range A:B         full-range mode over market days A to B inclusive (same as --from A
                      --to B --all)
  --all               full-range mode over --from to --to: every interval of every day. Cost:
                      about 288 x days intervals at about 1 minute each plus compile time, and
                      one NEMDE zip download per day
  --at T1,T2,...      explicit intervals (interval ends, e.g. 2026-06-03T15:00:00) instead
  --intervention 0|1  pricing run (0, default) or physical run (1) of AEMSim

Output and sources
  --out DIR           results directory (default $STORE_ROOT/compare_<timestamp> if that disk
                      exists, else ./compare_<timestamp>). Pass the same DIR again to resume
  --hive DIR          hive cache (default ~/.nemdb_cache), read only
  --skip-aemsim       reuse AEMSim results already in --out
  --skip-nempy        do not run nempy (reuse nempy results already in --out)
  --python EXE        python with nempy and mip installed (default \$NEMPY_PYTHON or python3)
  --nempy-src DIR     nempy source checkout's src directory (default \$NEMPY_SRC)
  --nempy-dir DIR     nempy working files: xml_cache/, db/, out/ (default <out>/nempy). Point
                      several runs at one directory to share the downloaded XML
  --no-fetch          do not download NEMDE case files (use the XML already cached)
  --retry-failed      solve again the intervals recorded as failed

Limits
  --time-limit SEC    HiGHS time limit per interval (default 600); a hit is a recorded failure
  --memory-limit-gb G DuckDB memory limit (default 3); DuckDB threads are fixed at 2
  --tmp-dir DIR       TMPDIR and DuckDB spill directory (default <out>/tmp)
  --min-ram-gb G      refuse to start with less available RAM (default 6)

  --dry-run           print the selection, download estimate and commands; solve and download nothing
  --help              this text

Outputs in --out: comparison_long.csv, summary.md, summary_metrics.csv, classification.csv,
aemsim_long.csv, aemsim_status.csv, skipped_constraints.csv, ramp_violations.csv, intervals.txt.
"""

const FLAGS = ["help", "dry-run", "all", "skip-aemsim", "skip-nempy", "no-fetch", "retry-failed"]
const VALUE_OPTIONS = [
    "n", "seed", "at", "from", "to", "days", "range", "intervention", "out", "hive", "python", "nempy-src",
    "nempy-dir", "time-limit", "memory-limit-gb", "tmp-dir", "min-ram-gb",
]

# Parses `--key value`, `--key=value` and bare flags into a Dict.
function parse_options(args)
    opts = Dict{String, Any}()
    i = 1
    while i <= length(args)
        arg = args[i]
        startswith(arg, "--") || error("Unexpected argument '$arg'; see --help.")
        key, eq, value = partition(arg[3:end], "=")
        if key in FLAGS
            opts[key] = true
        elseif key in VALUE_OPTIONS
            if isempty(eq)
                i < length(args) || error("Option --$key needs a value.")
                value = args[i += 1]
            end
            opts[key] = value
        else
            error("Unknown option --$key; see --help.")
        end
        i += 1
    end
    return opts
end

partition(s, sep) = (p = findfirst(sep, s); isnothing(p) ? (s, "", "") : (s[1:(first(p) - 1)], sep, s[(last(p) + 1):end]))

option(opts, key, default) = get(opts, key, default)
int_option(opts, key, default) = parse(Int, string(option(opts, key, default)))

# MemAvailable from /proc/meminfo, in GB.
function available_ram_gb()
    for line in eachline("/proc/meminfo")
        startswith(line, "MemAvailable:") && return parse(Int, split(line)[2]) / 1024^2
    end
    return Inf
end

# Free space in GB on the filesystem holding `path` (an existing ancestor is used).
function free_disk_gb(path)
    while !ispath(path)
        path = dirname(path)
    end
    out = read(`df -Pk $path`, String)
    return parse(Int, split(split(strip(out), '\n')[end])[4]) / 1024^2
end

function select_intervals(opts)
    from = Date(option(opts, "from", "2026-06-01"))
    to = Date(option(opts, "to", "2026-06-30"))
    all_mode = haskey(opts, "all")
    if haskey(opts, "at")
        intervals = sort!(unique(DateTime.(split(opts["at"], ','))))
        return (; intervals, from = Date(first(intervals)), to = Date(last(intervals)), mode = "explicit")
    end
    if haskey(opts, "range")
        a, b = split(opts["range"], ':')
        from, to, all_mode = Date(a), Date(b), true
    end
    if all_mode
        return (; intervals = comparison_intervals(from, to), from, to, mode = "full range")
    end
    n = int_option(opts, "n", 100)
    days = int_option(opts, "days", min(n, 10))
    intervals = comparison_sample(from, to; n = n, seed = int_option(opts, "seed", 1), days = days)
    return (; intervals, from, to, mode = "random (n = $n, seed = $(int_option(opts, "seed", 1)), days <= $days)")
end

default_out() = joinpath(isdir(STORE_ROOT) ? STORE_ROOT : pwd(), "compare_" * Dates.format(now(), "yyyymmdd_HHMMSS"))

function nempy_commands(opts, paths, python, src)
    src_args = isempty(src) ? String[] : ["--nempy-src", src]
    fetch = `$python $(joinpath(NEMPY_SCRIPTS, "fetch_xml.py")) --intervals-file $(paths.intervals_file) --xml-cache $(paths.xml_cache) --dl-dir $(paths.dl) $src_args`
    build = `$python $(joinpath(NEMPY_SCRIPTS, "build_db.py")) --db $(paths.db) --intervals-file $(paths.intervals_file) --cache $(opts["hive"]) --tmp $(opts["tmp-dir"]) --memory-limit $(opts["memory-limit-gb"])GB`
    run_ = `$python $(joinpath(NEMPY_SCRIPTS, "run_interval_xml.py")) --db $(paths.db) --xml-cache $(paths.xml_cache) --out $(paths.out) --intervals-file $(paths.intervals_file) $src_args`
    return (; fetch, build, run = run_)
end

function typed_aemsim(path)
    isfile(path) || return AEMS.aemsim_long(DataFrame(interval = DateTime[], metric_family = String[], key = String[], ours = Float64[], published = Float64[]))
    raw = read_comparison_csv(path)
    return DataFrame(;
        interval = DateTime.(raw.interval), metric_group = String.(raw.metric_group), key = String.(raw.key),
        aemsim = Union{Missing, Float64}[AEMS._parse_float(x) for x in raw.aemsim],
        nemde = Union{Missing, Float64}[AEMS._parse_float(x) for x in raw.nemde],
    )
end

function read_status(path)
    isfile(path) || return DataFrame(interval = DateTime[], status = String[], seconds = Union{Missing, Float64}[], message = Union{Missing, String}[])
    raw = read_comparison_csv(path)
    return DataFrame(;
        interval = DateTime.(raw.interval), status = String.(raw.status),
        seconds = Union{Missing, Float64}[AEMS._parse_float(x) for x in raw.seconds], message = raw.message,
    )
end

function read_typed_skipped(path)
    isfile(path) || return DataFrame(interval = DateTime[], constraint = String[], stage = String[], reason = String[], n_missing = Int[])
    raw = read_comparison_csv(path)
    return DataFrame(;
        interval = DateTime.(raw.interval), constraint = String.(raw.constraint), stage = String.(raw.stage),
        reason = String.(raw.reason), n_missing = parse.(Int, raw.n_missing),
    )
end

function run_aemsim(opts, intervals, out)
    status_file = joinpath(out, "aemsim_status.csv")
    previous = read_status(status_file)
    retry = haskey(opts, "retry-failed")
    done = Set(previous.interval[retry ? previous.status .== "ok" : trues(nrow(previous))])
    todo = filter(!in(done), intervals)
    println("AEMSim: $(length(intervals) - length(todo)) of $(length(intervals)) intervals already recorded; solving $(length(todo))")
    isempty(todo) && return
    db = aem_connect(HiveConfiguration(hive_location = opts["hive"]))
    for setting in ("memory_limit='$(opts["memory-limit-gb"])GB'", "threads=2", "temp_directory='$(opts["tmp-dir"])'")
        AustralianElectricityMarkets._query(db, "SET $setting")
    end
    optimizer = optimizer_with_attributes(
        HiGHS.Optimizer, "output_flag" => false, "mip_rel_gap" => 0.0, "mip_abs_gap" => 1.0e-10,
        "time_limit" => float(option(opts, "time-limit", 600)),
    )
    intervention = int_option(opts, "intervention", 0)
    for (i, t) in enumerate(todo)
        before = Set(readdir(opts["tmp-dir"]))
        started = time()
        message = missing
        n_skipped, n_ramp, max_ramp = missing, missing, missing
        try
            result = replicate_interval(db, t; intervention = intervention, optimizer = optimizer)
            rows = AEMS.aemsim_long(DataFrame(AEMS._comparison_rows(result.comparison, t, "compare")))
            write_comparison_csv(joinpath(out, "aemsim_long.csv"), rows; append = true)
            skipped = result.skipped_constraints
            write_comparison_csv(
                joinpath(out, "skipped_constraints.csv"),
                DataFrame(; interval = fill(t, nrow(skipped)), constraint = skipped.constraint, stage = String.(skipped.stage), reason = String.(skipped.reason), n_missing = skipped.n_missing);
                append = true,
            )
            ramp = result.ramp_violations
            isempty(ramp) || write_comparison_csv(joinpath(out, "ramp_violations.csv"), insertcols(ramp, 1, :interval => fill(t, nrow(ramp))); append = true)
            n_skipped, n_ramp = nrow(skipped), nrow(ramp)
            max_ramp = isempty(ramp) ? 0.0 : maximum(ramp.MW)
            state = "ok"
        catch err
            message = first(split(sprint(showerror, err), '\n'))
            state = "failed"
        end
        seconds = time() - started
        write_comparison_csv(
            status_file,
            DataFrame(; interval = [t], status = [state], seconds = [round(seconds; digits = 2)], n_skipped = [n_skipped], n_ramp_violations = [n_ramp], max_ramp_violation_mw = [max_ramp], message = [message]);
            append = true,
        )
        # PSI leaves one scratch directory per build in TMPDIR.
        for d in setdiff(readdir(opts["tmp-dir"]), before)
            rm(joinpath(opts["tmp-dir"], d); recursive = true, force = true)
        end
        println("[$i/$(length(todo))] $t $state $(round(seconds; digits = 1)) s", ismissing(message) ? "" : " ($message)")
        flush(stdout)
        GC.gc()
    end
    return
end

function nempy_available(python, src)
    isempty(src) || return success(`$python -c "import sys; sys.path.insert(0, '$src'); import nempy, mip"`)
    return success(`$python -c "import nempy, mip"`)
end

function run_nempy(opts, intervals, out, paths)
    python = option(opts, "python", get(ENV, "NEMPY_PYTHON", "python3"))
    src = option(opts, "nempy-src", get(ENV, "NEMPY_SRC", ""))
    pending = filter(t -> !isfile(joinpath(paths.out, nempy_tag(t), "done")), intervals)
    println("nempy: $(length(intervals) - length(pending)) of $(length(intervals)) intervals already done; running $(length(pending))")
    isempty(pending) && return
    if !nempy_available(python, src)
        println("nempy is not available with '$python' (import nempy, mip failed): continuing with AEMSim against NEMDE only.")
        println("See $(joinpath(NEMPY_SCRIPTS, "README.md")) for the setup, or pass --python and --nempy-src.")
        return
    end
    mkpath(paths.out)
    write(paths.intervals_file, join(nempy_stamp.(pending), "\n") * "\n")
    cmds = nempy_commands(opts, paths, python, src)
    if !haskey(opts, "no-fetch")
        println("downloading NEMDE case files (about $(comparison_download_mb(pending)) MB)")
        success(run(ignorestatus(cmds.fetch))) || println("fetch_xml.py failed; intervals without XML will fail in nempy.")
    end
    success(run(ignorestatus(cmds.build))) || (println("build_db.py failed; skipping nempy."); return)
    # The harness runs in chunks so that a crash of the CBC solver costs one chunk, not the run.
    for chunk in Iterators.partition(pending, 25)
        file = joinpath(paths.base, "chunk.txt")
        write(file, join(nempy_stamp.(chunk), "\n") * "\n")
        run(ignorestatus(`$python $(joinpath(NEMPY_SCRIPTS, "run_interval_xml.py")) --db $(paths.db) --xml-cache $(paths.xml_cache) --out $(paths.out) --intervals-file $file $(isempty(src) ? String[] : ["--nempy-src", src])`))
    end
    return
end

function main(args)
    opts = parse_options(args)
    if haskey(opts, "help")
        print(USAGE)
        return 0
    end
    out = abspath(option(opts, "out", default_out()))
    opts["out"] = out
    opts["hive"] = abspath(expanduser(option(opts, "hive", "~/.nemdb_cache")))
    opts["tmp-dir"] = abspath(option(opts, "tmp-dir", joinpath(out, "tmp")))
    opts["memory-limit-gb"] = int_option(opts, "memory-limit-gb", 3)
    selection = select_intervals(opts)
    intervals = selection.intervals
    base = abspath(option(opts, "nempy-dir", joinpath(out, "nempy")))
    paths = (;
        base, xml_cache = joinpath(base, "xml_cache"), db = joinpath(base, "db", "historical_mms.db"),
        out = joinpath(base, "out"), dl = joinpath(base, "dl"), intervals_file = joinpath(base, "intervals.txt"),
    )
    python = option(opts, "python", get(ENV, "NEMPY_PYTHON", "python3"))
    src = option(opts, "nempy-src", get(ENV, "NEMPY_SRC", ""))
    days = unique(AEMS._market_day.(intervals))

    println("Mode: $(selection.mode); market days $(selection.from) to $(selection.to)")
    println("Selected $(length(intervals)) intervals on $(length(days)) market days: $(join(days, ", "))")
    println("Estimated NEMDE download: about $(comparison_download_mb(intervals)) MB (one zip per market day, less when cached)")
    println("Output directory: $out")
    if haskey(opts, "dry-run")
        println("\nDry run: nothing is solved or downloaded. Intervals:")
        foreach(t -> println("  ", t), intervals)
        haskey(opts, "skip-aemsim") || println("\nAEMSim: replicate_interval(db, t; intervention = $(int_option(opts, "intervention", 0))) for each interval not in $(joinpath(out, "aemsim_status.csv")), HiGHS time limit $(option(opts, "time-limit", 600)) s")
        if !haskey(opts, "skip-nempy")
            cmds = nempy_commands(opts, paths, python, src)
            println("\nnempy commands:")
            haskey(opts, "no-fetch") || println("  ", cmds.fetch)
            println("  ", cmds.build)
            println("  ", cmds.run, "   (in chunks of 25 intervals)")
        end
        return 0
    end

    ram = available_ram_gb()
    ram >= int_option(opts, "min-ram-gb", 6) || (println(stderr, "Only $(round(ram; digits = 1)) GB RAM available; need $(int_option(opts, "min-ram-gb", 6)) GB (--min-ram-gb)."); return 1)
    need_gb = 2 + 0.3 * length(days)
    disk = free_disk_gb(out)
    disk >= need_gb || (println(stderr, "Only $(round(disk; digits = 1)) GB free for $out; need about $(round(need_gb; digits = 1)) GB."); return 1)
    mkpath(out)
    mkpath(opts["tmp-dir"])
    ENV["TMPDIR"] = opts["tmp-dir"]
    write(joinpath(out, "intervals.txt"), join(Dates.format.(intervals, "yyyy-mm-ddTHH:MM:SS"), "\n") * "\n")

    haskey(opts, "skip-aemsim") || run_aemsim(opts, intervals, out)
    haskey(opts, "skip-nempy") || run_nempy(opts, intervals, out, paths)

    aemsim = filter(:interval => in(Set(intervals)), typed_aemsim(joinpath(out, "aemsim_long.csv")))
    nempy = reduce(vcat, (read_nempy_interval(paths.out, t) for t in intervals); init = copy(AEMS._EMPTY_NEMPY))
    long = comparison_long(aemsim, nempy)
    write_comparison_csv(joinpath(out, "comparison_long.csv"), long)
    write_comparison_csv(joinpath(out, "summary_metrics.csv"), comparison_summary(long))
    write_comparison_csv(joinpath(out, "classification.csv"), comparison_classify(long))
    status = filter(:interval => in(Set(intervals)), read_status(joinpath(out, "aemsim_status.csv")))
    skipped = filter(:interval => in(Set(intervals)), read_typed_skipped(joinpath(out, "skipped_constraints.csv")))
    report = comparison_markdown(long, status; skipped = skipped)
    write(joinpath(out, "summary.md"), report)
    println("\nWrote $(nrow(long)) rows to $(joinpath(out, "comparison_long.csv")) and the report to $(joinpath(out, "summary.md"))")
    return 0
end

exit(main(ARGS))
