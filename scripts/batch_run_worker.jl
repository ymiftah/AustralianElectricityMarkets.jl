# Worker of the overnight batch runner: runs trading days in this process and writes their
# outputs into the day folders. Included only by `batch_run.jl --worker-loop`, so the
# supervisor never loads the market packages.

module BatchRunWorker

using AustralianElectricityMarkets
using AustralianElectricityMarketsSimulations
using Chain
using DataFrames
using Dates
using DuckDB
using HiGHS
import HDF5
using TOML
using SHA
import PowerSimulations as PSI
using ..BatchRunSupport

const _SIMULATION_NAME = "problem_workflow"
const _DECISION_NAME = "dispatch"
const _TIMING_COLUMNS = (
    "timestamp_utc", "interval_aest", "execution_count", "phase", "wall_s", "allocated_bytes",
    "gc_s", "compilation_s", "timed_solve_s", "pricing_s", "auxiliary_s", "schema_version",
)
const _TIMING_SCHEMA_VERSION = 2
const _TimingRow = NamedTuple{
    Symbol.(_TIMING_COLUMNS),
    Tuple{String, String, Int, String, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Int},
}
const _QUARTER_HOUR_MS = 900_000

_no_phase(phase) = nothing

# Logs the skipped-constraint count by reason, for a build or solve that failed.
function _log_skipped_constraints(skipped::DataFrame)
    by_reason = combine(groupby(skipped, :reason), nrow => :n)
    counts = join(("$(r.reason)=$(r.n)" for r in eachrow(sort(by_reason, :reason))), ", ")
    @error "Skipped constraints at failure: $(nrow(skipped)) ($counts)" skipped
    return
end

# The NEMDE system over `first_step` through `last_step`, plus the two intervals the input preparation reads ahead.
function _build_system(db, first_step, last_step, folder, time_series_in_memory)
    horizon = first_step:DISPATCH_INTERVAL:(last_step + 2DISPATCH_INTERVAL)
    ts_directory = time_series_in_memory ? nothing : joinpath(folder, "time_series")
    time_series_in_memory || mkpath(ts_directory)
    return nem_system(
        db, NEMDEConfiguration(); date_range = horizon, intervention = 0, interval_flow_limits = false,
        time_series_in_memory, time_series_directory = ts_directory,
    )
end

# The solver statistics of `results` as the `solver_stats.csv` table, one row per entry of `steps`.
function _solver_stats_table(results, steps, k)
    stats = PSI.read_optimizer_stats(results)
    nrow(stats) == length(steps) || error("Chunk $k: $(nrow(stats)) optimizer stat rows for $(length(steps)) steps.")
    return DataFrame(
        SETTLEMENTDATE = collect(steps), chunk = fill(k, length(steps)),
        objective_value = stats.objective_value, solver_solve_time = stats.solver_solve_time,
        timed_solve_time = stats.timed_solve_time,
        timed_calculate_dual_variables = stats.timed_calculate_dual_variables,
        termination_status = stats.termination_status,
    )
end

# The ramp-limited unit rows of the constraint violations, as `ramp_violations.csv`.
function _ramp_violations(violations)
    return @chain violations begin
        subset(:family => ByRow(==("unit_ramp")))
        select(:name => :DUID, :DateTime, :MW, :direction)
    end
end

# Builds, executes and compares one chunk of `steps` in `folder`; returns its tables and phase timings.
function _run_chunk(
        db, steps::StepRange{DateTime}, k::Integer, folder::AbstractString;
        optimizer, time_series_in_memory::Bool, cache_size_mib::Integer, on_phase, problem = NEMDispatchProblem,
        fast_start::Bool = true,
    )
    template = template_nemde()
    on_phase(:system_build)
    t0 = time()
    sys = _build_system(db, first(steps), last(steps), folder, time_series_in_memory)
    system_build_s = time() - t0

    on_phase(:model_build)
    t1 = time()
    (; models, sequence, dispatch) = nem_dispatch_sequence(
        problem, template, sys; optimizer, initial_time = first(steps), name = _DECISION_NAME, fast_start,
    )
    skipped = template_skipped_constraints(sys, template)
    simulation = PSI.Simulation(;
        name = _SIMULATION_NAME, steps = length(steps), models, sequence,
        simulation_folder = folder, initial_time = first(steps),
    )
    status = PSI.build!(simulation; store_systems_in_results = false)
    simulation_build_s = time() - t1
    if status != PSI.SimulationBuildStatus.BUILT
        _log_skipped_constraints(skipped)
        error("Range from $(first(steps)) failed to build ($status); see the simulation logs.")
    end

    on_phase(:execute)
    t2 = time()
    status = try
        PSI.execute!(simulation; cache_size_mib)
    catch
        _log_skipped_constraints(skipped)
        rethrow()
    end
    execute_s = time() - t2
    if status != PSI.RunStatus.SUCCESSFULLY_FINALIZED
        _log_skipped_constraints(skipped)
        error("Range from $(first(steps)) failed to execute ($status); see the simulation logs.")
    end
    results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), _DECISION_NAME)
    _write_interval_timings!(simulation, dispatch, results)

    on_phase(:compare)
    t3 = time()
    solved = read_solved_interval(results, sys)
    comparison = compare_intervals(read_published_interval(db, steps), solved)
    violations = read_constraint_violations(results, sys)
    ramp = _ramp_violations(violations)
    solver_stats = _solver_stats_table(results, steps, k)
    compare_s = time() - t3
    return (;
        timings = (; system_build_s, simulation_build_s, execute_s, compare_s), comparison,
        skipped_constraints = insertcols(skipped, 1, :chunk => fill(k, nrow(skipped))),
        constraint_violations = violations, ramp_violations = ramp, solver_stats,
    )
end

"""
    _problem_day(db, steps::StepRange{DateTime}, folder; optimizer, time_series_in_memory, cache_size_mib, on_phase = _no_phase, problem = NEMDispatchProblem) -> NamedTuple
    _problem_day(db, day::Date, folder; kwargs...) -> NamedTuple

Runs the intervals `steps`, or the trading day `day`, in consecutive [`dispatch_chunks`](@ref) written to
`folder/chunk_<k>`. Each chunk is built on a one-chunk `nem_system`, executed and compared with the
published outcome. `on_phase` receives `:system_build`, `:model_build`, `:execute` and `:compare` for each
chunk.

# Arguments
- `db`: the `AEMDB` connection to the cache.
- `steps`, `day`: the interval-ending timestamps, or the trading day whose intervals
  [`trading_day_steps`](@ref) gives.
- `folder`: the output folder of the chunks.
- `optimizer`: the JuMP optimizer, e.g. from [`nemde_optimizer`](@ref).
- `time_series_in_memory`: whether time series are held in memory rather than written per chunk.
- `cache_size_mib`: the PSI results write cache in MiB.
- `on_phase`: optional callback receiving the phase names.
- `problem`: the NEM dispatch problem type, `NEMDispatchProblem` or `NEMClosedLoopDispatchProblem`.
- `fast_start`: run NEMDE's two fast-start runs when the system has a fast-start unit; `false` solves the single model.

# Returns
A `NamedTuple` of `chunks` (`chunk`, `start`, `stop`, `n_steps`, `folder`, `system_build_s`,
`simulation_build_s`, `execute_s`, `compare_s`), `skipped_constraints`, `comparison`, `ramp_violations`,
`constraint_violations` and `solver_stats`, stacked over the chunks.
"""
function _problem_day(
        db, steps::StepRange{DateTime}, folder::AbstractString;
        optimizer, time_series_in_memory::Bool, cache_size_mib::Integer, on_phase = _no_phase, problem = NEMDispatchProblem,
        fast_start::Bool = true,
    )
    chunks = dispatch_chunks(steps)
    folders = [joinpath(folder, "chunk_$k") for k in eachindex(chunks)]
    outs = map(eachindex(chunks)) do k
        _run_chunk(
            db, chunks[k], k, mkpath(folders[k]); optimizer, time_series_in_memory, cache_size_mib, on_phase, problem, fast_start,
        )
    end
    return _stack_chunks(outs, chunks, folders, length.(chunks))
end

"""
    _dispatch_intervals(db, intervals::Vector{DateTime}, folder; optimizer, time_series_in_memory, on_phase = _no_phase) -> NamedTuple

Runs the selected `intervals` of one trading day, which need not be consecutive. Each selected interval
is its own chunk: one `nem_system` over that interval and a one-step simulation of the
[`nem_dispatch_sequence`](@ref) (open loop, from AEMO's observed state, with both fast-start runs when the system
has a fast-start unit), then compared with the dispatch run's published outcome. Inputs between selected intervals
are never read.

# Arguments
- `db`: the `AEMDB` connection to the cache.
- `intervals`: the sorted interval-ending timestamps, all in one trading day.
- `folder`: the output folder of the chunks.
- `optimizer`: the JuMP optimizer, e.g. from [`nemde_optimizer`](@ref).
- `time_series_in_memory`: whether time series are held in memory rather than written per chunk.
- `on_phase`: optional callback receiving `:system_build`, `:execute` and `:compare` for each chunk.

# Returns
The `NamedTuple` of [`_problem_day`](@ref), where `chunks` counts the selected intervals in `n_steps`,
`simulation_build_s` sums the per-interval model builds and `execute_s` the solves and result reads.
"""
function _dispatch_intervals(
        db, intervals::Vector{DateTime}, folder::AbstractString;
        optimizer, time_series_in_memory::Bool, on_phase = _no_phase, fast_start::Bool = true,
    )
    chunks = [[t] for t in intervals]
    folders = [joinpath(folder, "chunk_$k") for k in eachindex(chunks)]
    outs = map(eachindex(chunks)) do k
        _sampled_chunk(db, chunks[k], k, mkpath(folders[k]); optimizer, time_series_in_memory, on_phase, fast_start)
    end
    return _stack_chunks(outs, chunks, folders, length.(chunks))
end

# Solves each of `intervals` as a one-step simulation of the run sequence on one shared system, keeping their
# comparison rows.
function _sampled_chunk(
        db, intervals::Vector{DateTime}, k::Integer, folder::AbstractString;
        optimizer, time_series_in_memory::Bool, on_phase, fast_start::Bool = true,
    )
    template = template_nemde()
    on_phase(:system_build)
    t0 = time()
    sys = _build_system(db, first(intervals), last(intervals), folder, time_series_in_memory)
    system_build_s = time() - t0

    on_phase(:execute)
    skipped = Ref(DataFrame())
    parts = map(enumerate(intervals)) do (i, t)
        t1 = time()
        (; models, sequence) = nem_dispatch_sequence(
            NEMDispatchProblem, template, sys; optimizer, initial_time = t, name = _DECISION_NAME, fast_start,
        )
        # The skipped-constraint report depends on the system and template only, so the first model gives it.
        i == 1 && (skipped[] = template_skipped_constraints(sys, template))
        output_dir = mktempdir(folder)
        simulation = PSI.Simulation(;
            name = _SIMULATION_NAME, steps = 1, models, sequence, simulation_folder = output_dir, initial_time = t,
        )
        status = PSI.build!(simulation; store_systems_in_results = false)
        build_s = time() - t1
        if status != PSI.SimulationBuildStatus.BUILT
            _log_skipped_constraints(skipped[])
            error("Interval $t failed to build ($status); see the logs.")
        end
        t2 = time()
        status = try
            PSI.execute!(simulation; enable_progress_bar = false)
        catch
            _log_skipped_constraints(skipped[])
            rethrow()
        end
        status == PSI.RunStatus.SUCCESSFULLY_FINALIZED || error("Interval $t failed to solve ($status).")
        results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), _DECISION_NAME)
        solved = read_solved_interval(results, sys)
        violations = read_constraint_violations(results, sys)
        stats = _solver_stats_table(results, [t], k)
        rm(output_dir; recursive = true)
        return (; solved, violations, stats, build_s, solve_s = time() - t2)
    end

    on_phase(:compare)
    t3 = time()
    selected = Set(intervals)
    published = read_published_interval(db, first(intervals):DISPATCH_INTERVAL:last(intervals))
    published = NamedTuple(
        table => subset(frame, :SETTLEMENTDATE => ByRow(in(selected))) for (table, frame) in pairs(published)
    )
    solved = NamedTuple(
        table => reduce(vcat, [getproperty(part.solved, table) for part in parts]) for table in keys(first(parts).solved)
    )
    violations = reduce(vcat, [part.violations for part in parts])
    return (;
        timings = (;
            system_build_s, simulation_build_s = sum(part.build_s for part in parts),
            execute_s = sum(part.solve_s for part in parts), compare_s = time() - t3,
        ),
        comparison = compare_intervals(published, solved),
        skipped_constraints = insertcols(skipped[], 1, :chunk => fill(k, nrow(skipped[]))),
        constraint_violations = violations, ramp_violations = _ramp_violations(violations),
        solver_stats = reduce(vcat, [part.stats for part in parts]),
    )
end

# Stacks the per-chunk tables of a day and tabulates the chunks, with `n_steps` intervals each.
function _stack_chunks(outs, chunks, folders, n_steps)
    stacked(field) = reduce(vcat, [getproperty(out, field) for out in outs])
    chunk_table = DataFrame(
        chunk = eachindex(chunks), start = first.(chunks), stop = last.(chunks), n_steps = n_steps,
        folder = folders,
    )
    for field in (:system_build_s, :simulation_build_s, :execute_s, :compare_s)
        chunk_table[!, field] = [getproperty(out.timings, field) for out in outs]
    end
    comparison = NamedTuple(
        table => reduce(vcat, [getproperty(out.comparison, table) for out in outs])
            for table in keys(first(outs).comparison)
    )
    return (;
        chunks = chunk_table, skipped_constraints = stacked(:skipped_constraints), comparison,
        ramp_violations = stacked(:ramp_violations), constraint_violations = stacked(:constraint_violations),
        solver_stats = stacked(:solver_stats),
    )
end

function _problem_day(db, day::Date, folder::AbstractString; kwargs...)
    return _problem_day(db, trading_day_steps(day), folder; kwargs...)
end

function _write_frame(path, frame)
    write_csv(path, names(frame), zip(eachcol(frame)...))
    return
end

function save_day(folder, result)
    for table in keys(result.comparison)
        _write_frame(joinpath(folder, "comparison_$table.csv"), result.comparison[table])
    end
    for field in (:chunks, :solver_stats, :skipped_constraints, :constraint_violations, :ramp_violations)
        _write_frame(joinpath(folder, "$field.csv"), result[field])
    end
    _write_frame(joinpath(folder, "summary.csv"), comparison_summary(result.comparison))
    return (;
        intervals = nrow(result.solver_stats), chunks = nrow(result.chunks),
        system_build_s = sum(result.chunks.system_build_s),
        model_build_s = sum(result.chunks.simulation_build_s),
        execute_s = sum(result.chunks.execute_s), compare_s = sum(result.chunks.compare_s),
        solver_s = sum(result.solver_stats.solver_solve_time),
        timed_solve_s = sum(result.solver_stats.timed_solve_time),
        dual_calculation_s = sum(result.solver_stats.timed_calculate_dual_variables),
    )
end

# The local clock's offset from UTC, rounded to a quarter hour to absorb the skew between the two reads.
function _utc_offset()
    return _round_utc_offset(Dates.value(Dates.now() - Dates.now(Dates.UTC)))
end

# `value` as a `Float64`, or `NaN` when it is missing.
_nan_if_missing(value) = ismissing(value) ? NaN : Float64(value)

# Rounds a UTC offset in milliseconds to the nearest quarter hour.
function _round_utc_offset(offset_ms::Real)
    return Dates.Millisecond(round(Int, offset_ms / _QUARTER_HOUR_MS) * _QUARTER_HOUR_MS)
end

"""
    _interval_timing_rows(simulation, model, results) -> Vector{_TimingRow}

Builds the `parameter_update` and `solve_and_write` rows of every executed step of `model`.
`parameter_update` runs from the step's start event to its last `ParameterUpdateEvent` (zero when
none is logged); `solve_and_write` runs from there to the step's done event.

# Arguments

  - `simulation`: the simulation whose recorder events are read.
  - `model`: the decision model whose steps are read.
  - `results`: the simulation results whose optimizer statistics supply the solver fields.

# Returns

  - `Vector{_TimingRow}`: one row per phase per step, with the fields of `_TIMING_COLUMNS`.
"""
function _interval_timing_rows(simulation, model, results)
    folder = PSI.get_simulation_dir(simulation)
    name = string(PSI.get_name(model))
    executions = filter(
        e -> string(e.model_name) == name,
        PSI.list_simulation_events(PSI.ProblemExecutionEvent, folder),
    )
    starts = sort(filter(e -> e.status == "start", executions); by = e -> e.step)
    dones = Dict(e.step => e for e in executions if e.status == "done")
    stats = PSI.read_optimizer_stats(results)
    nrow(stats) == length(starts) ||
        error("Model $name: $(nrow(stats)) optimizer stat rows for $(length(starts)) executions.")

    updates = Dict{DateTime, Vector{DateTime}}()
    for event in PSI.list_simulation_events(PSI.ParameterUpdateEvent, folder)
        string(event.model_name) == name || continue
        push!(get!(Vector{DateTime}, updates, event.simulation_time), PSI.IS.get_timestamp(event))
    end

    offset = _utc_offset()
    rows = _TimingRow[]
    for (i, start) in enumerate(starts)
        done = get(dones, start.step, nothing)
        isnothing(done) && error("Model $name: step $(start.step) has no done event.")
        started, finished = PSI.IS.get_timestamp(start), PSI.IS.get_timestamp(done)
        in_window = filter(t -> started <= t <= finished, get(updates, start.simulation_time, DateTime[]))
        updated = isempty(in_window) ? started : maximum(in_window)
        interval = string(start.simulation_time)
        count = start.step - 1
        stat = stats[i, :]
        push!(
            rows, (;
                timestamp_utc = string(updated - offset), interval_aest = interval, execution_count = count,
                phase = "parameter_update", wall_s = Dates.value(updated - started) / 1000,
                allocated_bytes = NaN, gc_s = NaN, compilation_s = NaN,
                timed_solve_s = NaN, pricing_s = NaN, auxiliary_s = NaN,
                schema_version = _TIMING_SCHEMA_VERSION,
            ),
        )
        push!(
            rows, (;
                timestamp_utc = string(finished - offset), interval_aest = interval, execution_count = count,
                phase = "solve_and_write", wall_s = Dates.value(finished - updated) / 1000,
                allocated_bytes = _nan_if_missing(stat.solve_bytes_alloc), gc_s = _nan_if_missing(stat.sec_in_gc),
                compilation_s = NaN, timed_solve_s = stat.timed_solve_time,
                pricing_s = stat.timed_calculate_dual_variables, auxiliary_s = stat.timed_calculate_aux_variables,
                schema_version = _TIMING_SCHEMA_VERSION,
            ),
        )
    end
    return rows
end

"""
    _write_interval_timings!(simulation, dispatch, results) -> String

Writes `interval_timings.csv` into the model's output directory, one row per phase per step from
[`_interval_timing_rows`](@ref). Fields the recorder does not provide are `NaN`. `timestamp_utc` is
the end of each phase, converted from local time with one offset, so a run spanning a DST change is
off by an hour after the change.

# Arguments

  - `simulation`: the simulation whose recorder events are read.
  - `model`: the decision model whose output directory receives the CSV.
  - `results`: the simulation results whose optimizer statistics supply the solver fields.

# Returns

  - `String`: the path of the written `interval_timings.csv`.
"""
function _write_interval_timings!(simulation, model, results)
    path = joinpath(PSI.get_output_dir(model), "interval_timings.csv")
    rows = _interval_timing_rows(simulation, model, results)
    write_csv(path, _TIMING_COLUMNS, rows)
    return path
end

# Writes `text` to `path` through a temporary file, so a polling supervisor never reads a partial file.
function _publish(path, text)
    open(path * ".tmp", "w") do io
        write(io, text)
    end
    Base.Filesystem.rename(path * ".tmp", path)
    return
end

# The provenance of this worker process, captured once at start: its revision, checkout state, and
# snapshots of the package and runner sources it loaded, under `folder/worker_<pid>`.
function _worker_provenance(folder)
    pid = getpid()
    worker_folder = joinpath(folder, "worker_$pid")
    package_root = dirname(dirname(pathof(AustralianElectricityMarkets)))
    revision = try
        readchomp(`git -C $package_root rev-parse HEAD`)
    catch
        "unknown"
    end
    checkout_status = try
        readchomp(`git -C $package_root status --porcelain`)
    catch
        "unknown"
    end
    package_source = joinpath(worker_folder, "package_source")
    package_hashes = BatchRunSupport.snapshot_package_sources(package_root, package_source)
    runner_source = joinpath(worker_folder, "runner_source")
    mkpath(runner_source)
    for name in readdir(@__DIR__)
        any(ext -> endswith(name, ext), (".jl", ".py", ".md")) && cp(joinpath(@__DIR__, name), joinpath(runner_source, name))
    end
    source_hashes = Dict(
        name => bytes2hex(sha256(read(joinpath(runner_source, name)))) for name in readdir(runner_source) if endswith(name, ".jl")
    )
    return (;
        pid, started_utc = string(now(UTC)), revision, checkout_status, package_source,
        package_source_hashes = package_hashes, runner_source, source_hashes,
    )
end

function main(folder, day::Date; worker = _worker_provenance(folder))
    config = TOML.parsefile(joinpath(folder, "run.toml"))
    day_folder = joinpath(folder, string(day))
    time_series_in_memory = parse(Bool, config["time-series-in-memory"])
    closed_loop = parse(Bool, get(config, "closed-loop", "false"))
    fast_start = parse(Bool, get(config, "fast-start", "true"))
    sampled = !isempty(config["sample"]) || !isempty(config["intervals-file"])
    day_intervals = sampled ? get(
            BatchRunSupport.intervals_by_day(BatchRunSupport.read_intervals_file(joinpath(folder, "selected_intervals.csv"))),
            day, DateTime[],
        ) : DateTime[]
    sampled && isempty(day_intervals) && error("No selected intervals fall in trading day $day.")
    provenance = Dict(
        "interval_sampling" => Dict{String, Any}(
            "mode" => isempty(config["sample"]) ? (isempty(config["intervals-file"]) ? "none" : "file") : "random",
            "sample" => config["sample"], "intervals_file" => config["intervals-file"],
            "seed" => config["seed"], "first" => config["first"], "last" => config["last"],
            "day_intervals" => length(day_intervals),
        ),
        "revision" => worker.revision, "supervisor_revision" => config["git_revision"],
        "worker_pid" => worker.pid, "worker_started_utc" => worker.started_utc,
        "package_source" => worker.package_source, "runner_source" => worker.runner_source,
        "time_series_in_memory" => time_series_in_memory, "closed_loop" => closed_loop, "fast_start" => fast_start,
        "checkout_status" => worker.checkout_status, "package_source_hashes" => worker.package_source_hashes,
        "optimization_level" => Int(Base.JLOptions().opt_level),
        "julia" => string(VERSION), "psi" => string(Base.pkgversion(PSI)),
        "highs_package" => string(Base.pkgversion(HiGHS)),
        "hdf5" => string(Base.pkgversion(HDF5)),
        "aem" => string(Base.pkgversion(AustralianElectricityMarkets)),
        "aem_simulations" => string(Base.pkgversion(AustralianElectricityMarketsSimulations)),
        "interval_time_zone" => "fixed AEST UTC+10", "intervention" => 0,
        "mip_rel_gap" => Dict(NEMDE_HIGHS_OPTIONS)["mip_rel_gap"], "mip_abs_gap" => Dict(NEMDE_HIGHS_OPTIONS)["mip_abs_gap"],
        "highs_options" => Dict{String, Any}(name => value for (name, value) in NEMDE_HIGHS_OPTIONS),
        "instrumentation" => "interval_timings.csv is read from PSI recorder events and optimizer stats after execute!; TimerOutputs trees in timers_*.toml overlap",
        "source_hashes" => worker.source_hashes,
    )
    mkpath(day_folder)
    open(joinpath(day_folder, "provenance.toml"), "w") do io
        TOML.print(io, provenance)
    end
    started_ns = parse(UInt64, config["started_ns"])
    elapsed() = (time_ns() - started_ns) / 1.0e9
    optimizer = nemde_optimizer(; output_flag = false, threads = parse(Int, config["solver-threads"]))
    try
        chunk_index = 0
        function on_phase(phase)
            phase == :system_build && (chunk_index += 1)
            if phase in (:execute, :compare)
                label = phase == :execute ? "build" : "execute"
                timer = phase == :execute ? PSI.BUILD_PROBLEMS_TIMER : PSI.RUN_SIMULATION_TIMER
                open(joinpath(day_folder, "timers_$(label)_chunk_$(chunk_index).toml"), "w") do io
                    TOML.print(io, PSI.TimerOutputs.todict(timer))
                end
            end
            write_status(folder, string(phase); trading_day = string(day))
            event = (; timestamp_utc = string(now(UTC)), elapsed_s = elapsed(), trading_day = day, phase)
            write_csv(joinpath(folder, "phases.csv"), keys(event), [values(event)]; append = true)
            println("$(event.timestamp_utc) $day $phase elapsed=$(round(event.elapsed_s; digits = 2))s")
            flush(stdout)
            return
        end
        db = aem_connect(HiveConfiguration(hive_location = config["hive"]))
        try
            result = if sampled
                _dispatch_intervals(db, day_intervals, day_folder; optimizer, time_series_in_memory, on_phase, fast_start)
            else
                _problem_day(
                    db, BatchRunSupport.batch_steps(config, day), day_folder;
                    optimizer, time_series_in_memory, cache_size_mib = parse(Int, config["cache-size-mib"]), on_phase,
                    problem = closed_loop ? NEMClosedLoopDispatchProblem : NEMDispatchProblem, fast_start,
                )
            end
            on_phase(:export)
            totals = save_day(day_folder, result)
            println("Completed $day: $totals")
            flush(stdout)
            _publish(
                joinpath(day_folder, "worker_outcome.toml"),
                sprint(TOML.print, Dict(string(k) => v for (k, v) in pairs(totals))),
            )
        finally
            DuckDB.close(db.db)
        end
    catch err
        _publish(joinpath(day_folder, "worker_error.txt"), sprint(showerror, err, catch_backtrace()) * "\n")
        rethrow()
    end
    return
end

# Runs each trading day named on stdin, one per line, in this process until stdin closes. A failed day
# is recorded in its folder and the next day runs.
function serve(folder)
    worker = _worker_provenance(folder)
    for line in eachline(stdin)
        isempty(strip(line)) && continue
        day = Date(strip(line))
        try
            main(folder, day; worker)
        catch err
            err isa InterruptException && rethrow()
            error_path = joinpath(folder, string(day), "worker_error.txt")
            isfile(error_path) || _publish(error_path, sprint(showerror, err, catch_backtrace()) * "\n")
        end
        # Timers are reset between days so a sampled day's first timer file does not hold the previous day's last build.
        PSI.TimerOutputs.reset_timer!(PSI.BUILD_PROBLEMS_TIMER)
        PSI.TimerOutputs.reset_timer!(PSI.RUN_SIMULATION_TIMER)
        GC.gc()
        # WeakKeyDict entries are purged only on access, so touching each drops the finished day's model and system.
        for dict in (
                AustralianElectricityMarketsSimulations._COEFFICIENT_TARGETS,
                AustralianElectricityMarketsSimulations._BOUND_TARGETS,
                AustralianElectricityMarketsSimulations._BUILD_SCRATCH,
            )
            length(dict)
        end
        GC.gc()
        write_csv(
            joinpath(folder, "worker_memory.csv"), ("trading_day", "pid", "gc_live_mib", "rss_mib"),
            [(day, Libc.getpid(), Base.gc_live_bytes() / 2^20, _rss_mib())]; append = true,
        )
    end
    return
end

# Resident set size in MiB from `/proc/self/statm`, or `NaN` where that file does not exist.
function _rss_mib()
    isfile("/proc/self/statm") || return NaN
    resident_pages = parse(Int, split(read("/proc/self/statm", String))[2])
    return resident_pages * 4096 / 2^20
end

end
