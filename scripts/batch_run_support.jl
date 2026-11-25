module BatchRunSupport

using Dates
using Random
using TOML
using SHA

export scheduled_days, trading_steps, batch_steps, may_start_day, parse_options, write_status,
    read_status, write_csv, supervise, run_schedule, sample_intervals, read_intervals_file,
    intervals_by_day, selected_intervals

# The package files whose sources are hashed and snapshotted: a commit alone does not identify a dirty checkout.
function package_source_files(root)
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
    return files
end

function package_source_hashes(root)
    return Dict(relpath(path, root) => bytes2hex(sha256(read(path))) for path in package_source_files(root))
end

# Copies each package file under `output` and returns the hashes of the bytes copied, reading each file once.
function snapshot_package_sources(root, output)
    hashes = Dict{String, String}()
    for path in package_source_files(root)
        relative = relpath(path, root)
        data = read(path)
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

# The trading day of an interval ending at `t`.
_trading_day(t::DateTime) = Date(t - Hour(4) - Minute(5))

"""
    batch_steps(options, day::Date) -> StepRange{DateTime}

Returns the interval-ending timestamps to run for `day`: the `intervals` five-minute steps from `start`
when `start` is set, otherwise the whole trading day.

# Arguments
- `options`: the parsed options or the `run.toml` configuration, with string values.
- `day`: the trading day.

# Returns
A `StepRange{DateTime}` with a five-minute step.
"""
function batch_steps(options, day::Date)
    isempty(options["start"]) && return trading_steps(day)
    start = DateTime(options["start"])
    return start:Minute(5):(start + Minute(5) * (parse(Int, options["intervals"]) - 1))
end

"""
    sample_intervals(first_day::Date, last_day::Date, n::Integer, seed::Integer) -> Vector{DateTime}

Draws `n` distinct interval-ending timestamps uniformly from the five-minute grid of the trading days
`first_day` through `last_day`, from 04:05 on `first_day` to 04:00 on the day after `last_day`.

# Arguments
- `first_day`, `last_day`: the first and last trading day, inclusive.
- `n`: the number of intervals, at most the number of grid points.
- `seed`: the seed of the draw; the same seed and period give the same intervals.

# Returns
The sorted `Vector{DateTime}` of the drawn interval-ending timestamps.
"""
function sample_intervals(first_day::Date, last_day::Date, n::Integer, seed::Integer)
    grid = first(trading_steps(first_day)):Minute(5):last(trading_steps(last_day))
    0 < n <= length(grid) || throw(ArgumentError("--sample must be between 1 and $(length(grid)) for this period, got $n"))
    return sort!(grid[randperm(Xoshiro(seed), length(grid))[1:n]])
end

"""
    read_intervals_file(path) -> Vector{DateTime}

Reads a CSV of interval-ending timestamps with the header `interval` and one ISO timestamp per row.

# Arguments
- `path`: the CSV file.

# Returns
The sorted `Vector{DateTime}`. Throws `ArgumentError` for a missing or other header, an unparsable
timestamp, a timestamp off the five-minute grid, a duplicate, or an empty list.
"""
function read_intervals_file(path)
    isfile(path) || throw(ArgumentError("intervals file does not exist: $path"))
    lines = filter(!isempty, strip.(readlines(path)))
    !isempty(lines) && first(lines) == "interval" || throw(ArgumentError("intervals file must start with the header `interval`: $path"))
    intervals = map(lines[2:end]) do text
        t = try
            DateTime(text)
        catch
            throw(ArgumentError("intervals file has an unparsable timestamp: $text"))
        end
        second(t) == 0 && millisecond(t) == 0 && minute(t) % 5 == 0 ||
            throw(ArgumentError("intervals file timestamp is off the 5-minute grid: $text"))
        return t
    end
    isempty(intervals) && throw(ArgumentError("intervals file has no intervals: $path"))
    allunique(intervals) || throw(ArgumentError("intervals file has duplicate timestamps: $path"))
    return sort!(intervals)
end

"""
    selected_intervals(options) -> Union{Nothing, Vector{DateTime}}

Returns the interval-ending timestamps selected by `--intervals-file` or `--sample`, or `nothing` when
neither is set.

# Arguments
- `options`: the parsed options or the `run.toml` configuration, with string values.

# Returns
The sorted `Vector{DateTime}`, or `nothing` for whole-day and `--start` runs.
"""
function selected_intervals(options)
    if !isempty(options["intervals-file"])
        return read_intervals_file(options["intervals-file"])
    elseif !isempty(options["sample"])
        return sample_intervals(
            Date(options["first"]), Date(options["last"]), parse(Int, options["sample"]), parse(Int, options["seed"]),
        )
    end
    return nothing
end

"""
    intervals_by_day(intervals) -> Dict{Date, Vector{DateTime}}

Groups interval-ending timestamps by the trading day they belong to.

# Arguments
- `intervals`: the interval-ending timestamps.

# Returns
A `Dict` from trading day to the sorted timestamps of that day. An interval ending 00:05 through 04:00
belongs to the previous calendar day's trading day.
"""
function intervals_by_day(intervals)
    grouped = Dict{Date, Vector{DateTime}}()
    for t in sort(intervals)
        push!(get!(Vector{DateTime}, grouped, _trading_day(t)), t)
    end
    return grouped
end

# Requires `--start` and `--intervals` together, and a range that stays within one trading day.
function _validate_range(options)
    start_text, intervals_text = options["start"], options["intervals"]
    modes = count(!isempty, (start_text, options["intervals-file"], options["sample"]))
    modes <= 1 || throw(ArgumentError("--start/--intervals, --intervals-file and --sample are alternatives; give only one"))
    isempty(start_text) == isempty(intervals_text) ||
        throw(ArgumentError("--start and --intervals must be given together"))
    isempty(start_text) && return
    start = try
        DateTime(start_text)
    catch
        throw(ArgumentError("--start must be an ISO datetime such as 2026-06-04T04:05:00, got $start_text"))
    end
    second(start) == 0 && millisecond(start) == 0 && minute(start) % 5 == 0 ||
        throw(ArgumentError("--start must lie on a 5-minute boundary, got $start_text"))
    intervals = try
        parse(Int, intervals_text)
    catch
        throw(ArgumentError("--intervals must be an integer, got $intervals_text"))
    end
    intervals > 0 || throw(ArgumentError("--intervals must be positive"))
    day = _trading_day(start)
    start + Minute(5) * (intervals - 1) <= last(trading_steps(day)) ||
        throw(ArgumentError("--start with --intervals $intervals runs past trading day $day"))
    return
end

function parse_options(args)
    options = Dict(
        "first" => "2026-01-01", "last" => "2026-06-30", "hours" => "10",
        "seed" => "20261026", "hive" => joinpath(homedir(), ".nemdb_cache"),
        "output" => "", "intervals-file" => "", "sample" => "",
        "solver-threads" => "1", "cache-size-mib" => "64",
        "time-series-in-memory" => "true", "closed-loop" => "false", "fast-start" => "true", "start" => "", "intervals" => "",
    )
    iseven(length(args)) || throw(ArgumentError("options require --name value pairs; use --help"))
    for i in 1:2:length(args)
        key = startswith(args[i], "--") ? args[i][3:end] : ""
        haskey(options, key) || throw(ArgumentError("unknown option $(args[i]); use --help"))
        options[key] = args[i + 1]
    end
    Date(options["first"]) <= Date(options["last"]) || throw(ArgumentError("first day must not follow last day"))
    hours = parse(Float64, options["hours"])
    isfinite(hours) && hours > 0 || throw(ArgumentError("--hours must be finite and positive"))
    for key in ("solver-threads", "cache-size-mib")
        parse(Int, options[key]) > 0 || throw(ArgumentError("--$key must be positive"))
    end
    for key in ("time-series-in-memory", "closed-loop", "fast-start")
        try
            parse(Bool, options[key])
        catch
            throw(ArgumentError("--$key must be true or false"))
        end
    end
    parse(Int, options["seed"])
    isempty(options["output"]) && throw(ArgumentError("--output FOLDER is required; use --help"))
    _validate_range(options)
    if !isempty(options["intervals-file"]) || !isempty(options["sample"])
        parse(Bool, options["closed-loop"]) &&
            throw(ArgumentError("--closed-loop true needs consecutive intervals; it cannot be combined with --sample or --intervals-file"))
        isempty(options["sample"]) || (parse(Int, options["sample"]) > 0 || throw(ArgumentError("--sample must be positive")))
        options["intervals-file"] = isempty(options["intervals-file"]) ? "" : abspath(expanduser(options["intervals-file"]))
        selected_intervals(options)
    end
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

# The trading day and phase the worker last wrote to `status.toml`, or `("", "loading")` before it writes one.
function read_status(folder)
    path = joinpath(folder, "status.toml")
    status = isfile(path) ? TOML.parsefile(path) : Dict{String, Any}()
    return (; trading_day = get(status, "trading_day", ""), phase = get(status, "phase", "loading"))
end

function _csv_cell(value)
    ismissing(value) && return ""
    text = string(value)
    return occursin(r"[,\"\n\r]", text) ? "\"" * replace(text, "\"" => "\"\"") * "\"" : text
end

"""
    write_csv(path, columns, rows; append = false)

Writes `rows` (tuples or `NamedTuple`s of cells) under the header `columns`. `missing` is written as an
empty cell; cells with a comma, quote or newline are quoted. For a DataFrame `df`, pass `names(df)` and
`zip(eachcol(df)...)`.

# Arguments
- `path`: the CSV file.
- `columns`, `rows`: the header names and an iterable of rows, each iterating its cells in column order.
- `append`: append to an existing file, writing the header only when the file is new.

# Returns
`nothing`.
"""
function write_csv(path, columns, rows; append = false)
    header = !append || !isfile(path)
    open(path, append ? "a" : "w") do io
        header && println(io, join(_csv_cell.(columns), ','))
        for row in rows
            println(io, join((_csv_cell(cell) for cell in row), ','))
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
    end
    return (; completed, failed, reason = "exhausted")
end

function supervise(options)
    folder = options["output"]
    ispath(folder) && throw(ArgumentError("output already exists: $folder; choose a new run folder"))
    isdir(options["hive"]) || throw(ArgumentError("cache directory does not exist: $(options["hive"])"))
    mkpath(dirname(folder))
    mkdir(folder)
    started_ns = time_ns()
    config = merge(
        options, Dict(
            "started_ns" => string(started_ns), "started_utc" => string(now(UTC)),
            "julia_version" => string(VERSION), "mip_rel_gap" => "1e-9", "mip_abs_gap" => "1e-10"
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
    selected = selected_intervals(options)
    by_day = isnothing(selected) ? nothing : intervals_by_day(selected)
    days = if !isnothing(by_day)
        write_csv(joinpath(folder, "selected_intervals.csv"), ("interval",), ((t,) for t in selected))
        shuffle!(Xoshiro(parse(Int, options["seed"])), sort!(collect(keys(by_day))))
    elseif isempty(options["start"])
        scheduled_days(Date(options["first"]), Date(options["last"]), parse(Int, options["seed"]))
    else
        [_trading_day(DateTime(options["start"]))]
    end
    day_steps(day) = isnothing(by_day) ? batch_steps(options, day) : by_day[day]
    write_csv(
        joinpath(folder, "scheduled_days.csv"), ("order", "trading_day", "start", "stop", "n_intervals"),
        ((i, day, first(day_steps(day)), last(day_steps(day)), length(day_steps(day))) for (i, day) in enumerate(days))
    )
    write_status(folder, "loading")
    project = dirname(Base.active_project())
    script = joinpath(@__DIR__, "batch_run.jl")
    println("Run output: $folder\nDetailed log: $(joinpath(folder, "run.log"))")
    flush(stdout)
    command = `$(Base.julia_cmd()) --project=$project $script --worker-loop $folder`
    worker = Ref{Union{Nothing, Base.Process}}(nothing)
    outcome = open(joinpath(folder, "run.log"), "a") do log
        returned = false
        try
            result = run_schedule(
                folder, days, 3600 * parse(Float64, options["hours"]);
                elapsed = () -> (time_ns() - started_ns) / 1.0e9
            ) do day, day_folder
                run_day!(worker, command, folder, day, day_folder, started_ns, log)
                totals = TOML.parsefile(joinpath(day_folder, "worker_outcome.toml"))
                return (; (Symbol(k) => v for (k, v) in sort!(collect(totals); by = first))...)
            end
            returned = true
            result
        finally
            _stop_worker!(worker; graceful = returned)
        end
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
    println("Run finished. See $(joinpath(folder, "status.toml")) and days.csv.")
    outcome.completed > 0 || error("No trading days completed; inspect failures.csv and per-day worker_error.txt files")
    return
end

# Prints the worker's phase when it changes and at least once a minute; returns the updated notice state.
function _notify(folder, started_ns, worker, last; notice)
    elapsed_s = (time_ns() - started_ns) / 1.0e9
    status = read_status(folder)
    phase = "$(status.trading_day) $(status.phase)"
    (notice && (phase != last.phase || elapsed_s - last.at >= 60)) || return last
    println("$(now(UTC)) elapsed=$(round(elapsed_s; digits = 1))s $phase pid=$(getpid(worker))")
    flush(stdout)
    return (; at = elapsed_s, phase)
end

# Stops a worker that is still running: SIGTERM, then SIGKILL if it ignores SIGTERM for 5 s.
function _reap!(worker::Base.Process)
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
    return
end

# Stops the worker in `worker_ref` and empties the reference. Graceful closes its stdin so its loop ends, and
# waits up to 30 s for it to exit before `_reap!`; otherwise it is reaped at once.
function _stop_worker!(worker_ref; graceful::Bool)
    running = worker_ref[]
    worker_ref[] = nothing
    isnothing(running) && return
    if graceful && process_running(running)
        close(running.in)
        timedwait(() -> !process_running(running), 30.0; pollint = 0.05)
    end
    _reap!(running)
    return
end

# Starts the worker in `worker_ref` unless one is running there, and returns it.
function _start_worker!(worker_ref, command::Cmd, folder, day::Date, log)
    if isnothing(worker_ref[]) || !process_running(worker_ref[])
        write_status(folder, "loading"; trading_day = string(day))
        worker_ref[] = open(pipeline(command; stdout = log, stderr = log), "w")
    end
    return worker_ref[]
end

# Runs one day in the persistent worker in `worker_ref`, starting it when none is running, and waits until the
# day's `worker_outcome.toml` or `worker_error.txt` appears. The supervisor polls the status every `poll_seconds`
# and never interrupts an admitted day. Throws `ProcessFailedException` when the worker exits without either file.
function run_day!(
        worker_ref, command::Cmd, folder, day::Date, day_folder, started_ns, log;
        poll_seconds = 5.0, notice = true, on_poll = nothing,
    )
    worker = _start_worker!(worker_ref, command, folder, day, log)
    try
        println(worker, day)
        flush(worker)
    catch err
        err isa Union{Base.IOError, EOFError} || rethrow()
        # The worker died before reading the day: restart it and send the day once more.
        _stop_worker!(worker_ref; graceful = false)
        worker = _start_worker!(worker_ref, command, folder, day, log)
        println(worker, day)
        flush(worker)
    end
    outcome_path = joinpath(day_folder, "worker_outcome.toml")
    error_path = joinpath(day_folder, "worker_error.txt")
    last = (; at = -Inf, phase = "")
    while !isfile(outcome_path) && !isfile(error_path) && process_running(worker)
        isnothing(on_poll) || on_poll(worker)
        last = _notify(folder, started_ns, worker, last; notice)
        # Wake as soon as the day's files appear or the worker exits rather than at the next poll.
        timedwait(() -> isfile(outcome_path) || isfile(error_path) || !process_running(worker), poll_seconds; pollint = 0.05)
    end
    isfile(outcome_path) && return
    isfile(error_path) && error(read(error_path, String))
    _stop_worker!(worker_ref; graceful = false)
    throw(ProcessFailedException(worker))
end

end
