module ReplayBatchSupport

using Dates
using Random
using TOML
using SHA

export scheduled_days, trading_steps, may_start_day, parse_options, write_status,
    memory_sample, write_csv, supervise, run_schedule

# Snapshot package sources as well as scripts: a commit alone does not identify a dirty checkout.
function package_source_hashes(root)
    files = String[]
    for package in ("", "AustralianElectricityMarketsCache", "AustralianElectricityMarketsData", "AustralianElectricityMarketsSimulations")
        for name in ("Project.toml", "Manifest.toml", joinpath("test", "Project.toml"), joinpath("test", "Manifest.toml"))
            path = joinpath(root, package, name)
            isfile(path) && push!(files, path)
        end
        source = joinpath(root, package, "src")
        isdir(source) || continue
        for (folder, _, names) in walkdir(source), name in names
            endswith(name, ".jl") && push!(files, joinpath(folder, name))
        end
    end
    return Dict(relpath(path, root) => bytes2hex(sha256(read(path))) for path in files)
end

function snapshot_package_sources(root, output)
    hashes = Dict{String, String}()
    for relative in keys(package_source_hashes(root))
        data = read(joinpath(root, relative))
        destination = joinpath(output, relative)
        mkpath(dirname(destination))
        write(destination, data)
        hashes[relative] = bytes2hex(sha256(data))
    end
    return hashes
end

function scheduled_days(first_day::Date, last_day::Date, seed::Integer)
    first_day <= last_day || throw(ArgumentError("first day must not follow last day"))
    return shuffle!(Xoshiro(seed), collect(first_day:Day(1):last_day))
end

function trading_steps(day::Date)
    return (DateTime(day) + Hour(4) + Minute(5)):Minute(5):(DateTime(day + Day(1)) + Hour(4))
end

function may_start_day(elapsed_s::Real, budget_s::Real)
    return elapsed_s < budget_s
end

function parse_options(args)
    options = Dict(
        "first" => "2026-01-01", "last" => "2026-06-30", "hours" => "10",
        "seed" => "20261026", "hive" => joinpath(homedir(), ".nemdb_cache"),
        "output" => joinpath("/run/media/simba/Store/aem_validation", Dates.format(now(UTC), "yyyymmddTHHMMSS") * "Z_$(getpid())"),
        "sample-seconds" => "5", "solver-threads" => "1", "cache-size-mib" => "64",
        "time-series-in-memory" => "false",
    )
    iseven(length(args)) || throw(ArgumentError("options require --name value pairs; use --help"))
    for i in 1:2:length(args)
        key = startswith(args[i], "--") ? args[i][3:end] : ""
        haskey(options, key) || throw(ArgumentError("unknown option $(args[i]); use --help"))
        options[key] = args[i + 1]
    end
    Date(options["first"]) <= Date(options["last"]) || throw(ArgumentError("first day must not follow last day"))
    for key in ("hours", "sample-seconds")
        value = parse(Float64, options[key])
        isfinite(value) && value > 0 || throw(ArgumentError("--$key must be finite and positive"))
    end
    for key in ("solver-threads", "cache-size-mib")
        parse(Int, options[key]) > 0 || throw(ArgumentError("--$key must be positive"))
    end
    try
        parse(Bool, options["time-series-in-memory"])
    catch
        throw(ArgumentError("--time-series-in-memory must be true or false"))
    end
    parse(Int, options["seed"])
    options["output"] = abspath(expanduser(options["output"]))
    options["hive"] = abspath(expanduser(options["hive"]))
    return options
end

function write_status(folder, phase; trading_day = "", details = "")
    path = joinpath(folder, "status.toml")
    open(path * ".tmp", "w") do io
        TOML.print(
            io, Dict(
                "phase" => phase, "trading_day" => trading_day, "details" => details,
                "updated_utc" => string(now(UTC))
            )
        )
    end
    # Replace the status atomically while the supervisor reads it.
    Base.Filesystem.rename(path * ".tmp", path)
    return
end

function _proc_kib(path, key)
    for line in eachline(path)
        startswith(line, key * ":") && return parse(Float64, split(line)[2]) / 1024
    end
    return missing
end

function memory_sample(pid, folder, elapsed_s)
    status_file = joinpath(folder, "status.toml")
    status = isfile(status_file) ? TOML.parsefile(status_file) : Dict{String, Any}()
    proc = "/proc/$pid/status"
    return try
        (;
            timestamp_utc = string(now(UTC)), elapsed_s, pid,
            trading_day = get(status, "trading_day", ""), phase = get(status, "phase", "loading"),
            rss_mib = _proc_kib(proc, "VmRSS"), peak_rss_mib = _proc_kib(proc, "VmHWM"),
            virtual_mib = _proc_kib(proc, "VmSize"), available_host_mib = _proc_kib("/proc/meminfo", "MemAvailable"),
        )
    catch
        isdir("/proc/$pid") && rethrow()
        nothing
    end
end

function _csv_cell(value)
    ismissing(value) && return ""
    text = string(value)
    return occursin(r"[,\"\n\r]", text) ? "\"" * replace(text, "\"" => "\"\"") * "\"" : text
end

function write_csv(path, columns, rows; append = false)
    header = !append || !isfile(path)
    open(path, append ? "a" : "w") do io
        header && println(io, join(_csv_cell.(columns), ','))
        for row in rows
            println(io, join(_csv_cell.(collect(row)), ','))
        end
        flush(io)
    end
    return
end

function run_schedule(execute_day, folder, days, budget_s; elapsed)
    completed, failed = 0, 0
    for day in days
        may_start_day(elapsed(), budget_s) || return (; completed, failed, reason = "budget")
        day_folder = joinpath(folder, string(day))
        mkdir(day_folder)
        started = elapsed()
        write_status(folder, "starting_day"; trading_day = string(day))
        try
            totals = execute_day(day, day_folder)
            row = (; trading_day = day, status = "completed", elapsed_s = elapsed() - started, totals...)
            write_csv(joinpath(folder, "days.csv"), keys(row), [values(row)]; append = true)
            completed += 1
        catch err
            err isa InterruptException && rethrow()
            message = sprint(showerror, err, catch_backtrace())
            write(joinpath(day_folder, "error.txt"), message * "\n")
            row = (; trading_day = day, status = "failed", elapsed_s = elapsed() - started, error = message)
            write_csv(joinpath(folder, "failures.csv"), keys(row), [values(row)]; append = true)
            @error "Trading day $day failed; continuing with the next scheduled day" exception = (err, catch_backtrace())
            failed += 1
        end
        write_status(folder, "between_days"; trading_day = string(day), details = "completed=$completed failed=$failed")
        GC.gc()
    end
    return (; completed, failed, reason = "exhausted")
end

function supervise(options)
    Sys.islinux() || throw(ArgumentError("continuous process-memory sampling currently requires Linux /proc"))
    folder = options["output"]
    ispath(folder) && throw(ArgumentError("output already exists: $folder; choose a new run folder"))
    isdir(options["hive"]) || throw(ArgumentError("cache directory does not exist: $(options["hive"])"))
    mkpath(dirname(folder))
    mkdir(folder)
    started_ns = time_ns()
    config = merge(
        options, Dict(
            "started_ns" => string(started_ns), "started_utc" => string(now(UTC)),
            "julia_version" => string(VERSION), "mip_rel_gap" => "1e-8", "mip_abs_gap" => "1e-10"
        )
    )
    config["git_revision"] = try
        readchomp(`git -C $(@__DIR__) rev-parse HEAD`)
    catch
        "unknown"
    end
    open(joinpath(folder, "run.toml"), "w") do io
        TOML.print(io, config)
    end
    days = scheduled_days(Date(options["first"]), Date(options["last"]), parse(Int, options["seed"]))
    write_csv(
        joinpath(folder, "scheduled_days.csv"), ("order", "trading_day", "start", "stop"),
        ((i, day, first(trading_steps(day)), last(trading_steps(day))) for (i, day) in enumerate(days))
    )
    write_status(folder, "loading")
    project = dirname(Base.active_project())
    script = joinpath(@__DIR__, "replicate_random_days.jl")
    println("Replay output: $folder\nDetailed log: $(joinpath(folder, "run.log"))")
    flush(stdout)
    outcome = run_schedule(
        folder, days, 3600 * parse(Float64, options["hours"]);
        elapsed = () -> (time_ns() - started_ns) / 1.0e9
    ) do day, day_folder
        write_status(folder, "loading"; trading_day = string(day))
        command = `$(Base.julia_cmd()) --project=$project $script --worker $folder $day`
        run_worker(command, folder, started_ns, parse(Float64, options["sample-seconds"]))
        totals = TOML.parsefile(joinpath(day_folder, "worker_outcome.toml"))
        return (; (Symbol(k) => v for (k, v) in sort!(collect(totals); by = first))...)
    end
    open(joinpath(folder, "outcome.toml"), "w") do io
        TOML.print(
            io, Dict(
                "completed" => outcome.completed, "failed" => outcome.failed,
                "reason" => outcome.reason, "elapsed_s" => (time_ns() - started_ns) / 1.0e9
            )
        )
    end
    write_status(folder, "finished"; details = "$(outcome.reason): completed=$(outcome.completed) failed=$(outcome.failed)")
    println("Replay finished. See $(joinpath(folder, "status.toml")) and days.csv.")
    outcome.completed > 0 || error("No trading days completed; inspect failures.csv and per-day worker_error.txt files")
    return
end

# The supervisor owns this child. The admission deadline never interrupts an admitted child.
function run_worker(command::Cmd, folder, started_ns, sample_seconds; notice = true, on_sample = nothing)
    return open(joinpath(folder, "run.log"), "a") do log
        worker = run(pipeline(command; stdout = log, stderr = log); wait = false)
        worker_pid = getpid(worker)
        last_notice, last_phase = -Inf, ""
        try
            while process_running(worker)
                elapsed_s = (time_ns() - started_ns) / 1.0e9
                sample = memory_sample(worker_pid, folder, elapsed_s)
                if !isnothing(sample)
                    write_csv(joinpath(folder, "memory.csv"), keys(sample), [values(sample)]; append = true)
                    isnothing(on_sample) || on_sample(worker_pid)
                    phase = "$(sample.trading_day) $(sample.phase)"
                    if notice && (phase != last_phase || elapsed_s - last_notice >= 60)
                        println("$(sample.timestamp_utc) elapsed=$(round(elapsed_s; digits = 1))s $phase pid=$worker_pid RSS=$(sample.rss_mib) MiB peak=$(sample.peak_rss_mib) MiB")
                        flush(stdout)
                        last_notice, last_phase = elapsed_s, phase
                    end
                end
                sleep(sample_seconds)
            end
            wait(worker)
            success(worker) || throw(ProcessFailedException(worker))
        finally
            if process_running(worker)
                kill(worker, Base.SIGTERM)
                # Reap even children that ignore SIGTERM, without waiting indefinitely.
                timedwait(() -> !process_running(worker), 5.0; pollint = 0.05) == :timed_out && kill(worker, Base.SIGKILL)
                try
                    wait(worker)
                catch err
                    err isa ProcessFailedException || rethrow()
                end
            end
        end
        return worker_pid
    end
end

end
