# Worker of the overnight batch runner: replays one trading day in this process and writes its
# outputs into the day folder. Included only by `replay_batch.jl --worker`, so the supervisor
# never loads the market packages.

module ReplayBatchWorker

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
using ..ReplayBatchSupport

const _SIMULATION_NAME = "replay_workflow"
const _DECISION_NAME = "dispatch"
const _TIMING_COLUMNS = (
    "timestamp_utc", "interval_aest", "execution_count", "phase", "wall_s", "allocated_bytes",
    "gc_s", "compilation_s", "timed_solve_s", "pricing_s", "auxiliary_s", "schema_version",
)
const _TIMING_SCHEMA_VERSION = 2
const _QUARTER_HOUR_MS = 900_000

_no_phase(phase) = nothing

# Logs the skipped-constraint count by reason, for a build or solve that failed.
function _log_skipped_constraints(skipped::DataFrame)
    by_reason = combine(groupby(skipped, :reason), nrow => :n)
    counts = join(("$(r.reason)=$(r.n)" for r in eachrow(sort(by_reason, :reason))), ", ")
    @error "Skipped constraints at failure: $(nrow(skipped)) ($counts)" skipped
    return
end

# Builds, executes and compares one chunk of `steps` in `folder`; returns its tables and phase timings.
function _replay_chunk(
        db, steps::StepRange{DateTime}, k::Integer, folder::AbstractString;
        optimizer, time_series_in_memory::Bool, cache_size_mib::Integer, on_phase,
    )
    template = template_nemde()
    horizon = first(steps):DISPATCH_INTERVAL:(last(steps) + 2DISPATCH_INTERVAL)
    on_phase(:preflight)
    on_phase(:system_build)
    t0 = time()
    ts_directory = time_series_in_memory ? nothing : joinpath(folder, "time_series")
    time_series_in_memory || mkpath(ts_directory)
    sys = nem_system(
        db, NEMDEConfiguration(); date_range = horizon, intervention = 0, interval_flow_limits = false,
        time_series_in_memory, time_series_directory = ts_directory,
    )
    system_build_s = time() - t0

    t1 = time()
    skipped = prepare_replay!(sys, template, steps)
    on_phase(:model_build)
    model = PSI.DecisionModel(NEMDispatchProblem, template, sys; optimizer, initial_time = first(steps), name = _DECISION_NAME)
    models = PSI.SimulationModels(; decision_models = [model])
    sequence = PSI.SimulationSequence(; models, ini_cond_chronology = PSI.InterProblemChronology())
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
    _write_interval_timings!(simulation, model, results)

    on_phase(:compare)
    t3 = time()
    solved = read_solved_interval(results, sys)
    comparison = compare_intervals(read_published_interval(db, steps), solved)
    violations = read_constraint_violations(results, sys)
    ramp = @chain violations begin
        subset(:family => ByRow(==("unit_ramp")))
        select(:name => :DUID, :DateTime, :MW, :direction)
    end
    stats = PSI.read_optimizer_stats(results)
    nrow(stats) == length(steps) || error("Chunk $k: $(nrow(stats)) optimizer stat rows for $(length(steps)) steps.")
    solver_stats = DataFrame(
        SETTLEMENTDATE = collect(steps), chunk = fill(k, length(steps)),
        objective_value = stats.objective_value, solver_solve_time = stats.solver_solve_time,
        timed_solve_time = stats.timed_solve_time,
        timed_calculate_dual_variables = stats.timed_calculate_dual_variables,
        termination_status = stats.termination_status,
    )
    compare_s = time() - t3
    return (;
        timings = (; system_build_s, simulation_build_s, execute_s, compare_s), comparison,
        skipped_constraints = insertcols(skipped, 1, :chunk => fill(k, nrow(skipped))),
        constraint_violations = violations, ramp_violations = ramp, solver_stats,
    )
end

"""
    _replay_day(db, steps::StepRange{DateTime}, folder; optimizer, time_series_in_memory, cache_size_mib, on_phase = _no_phase) -> NamedTuple
    _replay_day(db, day::Date, folder; kwargs...) -> NamedTuple

Replays the intervals `steps`, or the trading day `day`, in consecutive [`replay_chunks`](@ref) written to
`folder/chunk_<k>`. Each chunk is built on a one-chunk `nem_system`, executed and compared with the
published outcome. `on_phase` receives `:preflight`, `:system_build`, `:model_build`, `:execute` and
`:compare` for each chunk.

# Arguments
- `db`: the `AEMDB` connection to the cache.
- `steps`, `day`: the interval-ending timestamps, or the trading day whose intervals
  [`trading_day_steps`](@ref) gives.
- `folder`: the output folder of the chunks.
- `optimizer`: the JuMP optimizer, e.g. from [`nemde_optimizer`](@ref).
- `time_series_in_memory`: whether time series are held in memory rather than written per chunk.
- `cache_size_mib`: the PSI results write cache in MiB.
- `on_phase`: optional callback receiving the phase names.

# Returns
A `NamedTuple` of `chunks` (`chunk`, `start`, `stop`, `n_steps`, `folder`, `system_build_s`,
`simulation_build_s`, `execute_s`, `compare_s`), `skipped_constraints`, `comparison`, `ramp_violations`,
`constraint_violations` and `solver_stats`, stacked over the chunks.
"""
function _replay_day(
        db, steps::StepRange{DateTime}, folder::AbstractString;
        optimizer, time_series_in_memory::Bool, cache_size_mib::Integer, on_phase = _no_phase,
    )
    chunks = replay_chunks(steps)
    folders = [joinpath(folder, "chunk_$k") for k in eachindex(chunks)]
    outs = map(eachindex(chunks)) do k
        _replay_chunk(
            db, chunks[k], k, mkpath(folders[k]); optimizer, time_series_in_memory, cache_size_mib, on_phase,
        )
    end
    stacked(field) = reduce(vcat, [getproperty(out, field) for out in outs])
    chunk_table = DataFrame(
        chunk = eachindex(chunks), start = first.(chunks), stop = last.(chunks), n_steps = length.(chunks),
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

function _replay_day(db, day::Date, folder::AbstractString; kwargs...)
    return _replay_day(db, trading_day_steps(day), folder; kwargs...)
end

function _write_frame(path, frame)
    write_csv(path, names(frame), eachrow(frame))
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

"""
    _round_utc_offset(offset_ms::Real) -> Dates.Millisecond

Rounds a UTC offset in milliseconds to the nearest quarter hour, which absorbs the skew between
the two clock reads that produce it.

# Arguments

  - `offset_ms::Real`: the offset in milliseconds.

# Returns

  - `Dates.Millisecond`: the offset rounded to a multiple of 15 minutes.
"""
function _round_utc_offset(offset_ms::Real)
    rounded = round(Int, offset_ms / _QUARTER_HOUR_MS) * _QUARTER_HOUR_MS
    return Dates.Millisecond(rounded)
end

"""
    _utc_offset() -> Dates.Millisecond

Returns the local clock's offset from UTC, rounded to the nearest quarter hour.

# Returns

  - `Dates.Millisecond`: the local-minus-UTC offset.
"""
function _utc_offset()
    offset = _round_utc_offset(Dates.value(Dates.now() - Dates.now(Dates.UTC)))
    return offset
end

"""
    _timing_seconds(from::DateTime, to::DateTime) -> Float64

Returns the length of the span from `from` to `to` in seconds.

# Arguments

  - `from::DateTime`: start of the span.
  - `to::DateTime`: end of the span.

# Returns

  - `Float64`: the span length in seconds.
"""
function _timing_seconds(from::DateTime, to::DateTime)
    seconds = Dates.value(to - from) / 1000
    return seconds
end

"""
    _timing_nan(value) -> Float64

Returns `value` as a `Float64`, or `NaN` when it is missing.

# Arguments

  - `value`: a number or `missing`.

# Returns

  - `Float64`: the converted value, or `NaN`.
"""
function _timing_nan(value)
    result = ismissing(value) ? NaN : Float64(value)
    return result
end

"""
    _interval_timing_rows(simulation, model, results) -> Vector{NamedTuple}

Builds the `parameter_update` and `solve_and_write` rows of every executed step of `model`.
The `parameter_update` span runs from the step's start event to the last `ParameterUpdateEvent`
logged for its simulation time, and is zero when none is logged. PSI then applies the
initial-condition updates and rebuilds the objective, and it logs no event for either, so both
fall in `solve_and_write`. That span also holds the solve, pricing, auxiliary calculation, result
write, native state update and warm start, and ends at the step's done event.

# Arguments

  - `simulation`: the simulation whose recorder events are read.
  - `model`: the decision model whose steps are read.
  - `results`: the simulation results whose optimizer statistics supply the solver fields.

# Returns

  - `Vector{NamedTuple}`: one row per phase per step, with the fields of `_TIMING_COLUMNS`.
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
    rows = NamedTuple[]
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
                phase = "parameter_update", wall_s = _timing_seconds(started, updated),
                allocated_bytes = NaN, gc_s = NaN, compilation_s = NaN,
                timed_solve_s = NaN, pricing_s = NaN, auxiliary_s = NaN,
                schema_version = _TIMING_SCHEMA_VERSION,
            ),
        )
        push!(
            rows, (;
                timestamp_utc = string(finished - offset), interval_aest = interval, execution_count = count,
                phase = "solve_and_write", wall_s = _timing_seconds(updated, finished),
                allocated_bytes = _timing_nan(stat.solve_bytes_alloc), gc_s = _timing_nan(stat.sec_in_gc),
                compilation_s = NaN, timed_solve_s = stat.timed_solve_time,
                pricing_s = stat.timed_calculate_dual_variables, auxiliary_s = stat.timed_calculate_aux_variables,
                schema_version = _TIMING_SCHEMA_VERSION,
            ),
        )
    end
    return rows
end

"""
    _write_interval_timings!(simulation, model, results) -> String

Writes `interval_timings.csv` into the model's output directory, one `parameter_update` and one
`solve_and_write` row per executed step. Fields the recorder does not provide are written as
`NaN`. `timestamp_utc` is the end of each phase. The recorder stamps events with the local clock
without a zone, so every timestamp is shifted by one offset, rounded to 15 minutes and read after
`execute!`; a run spanning a DST change is off by an hour for events after the change. The
`parameter_update` span ends at the last `ParameterUpdateEvent` of its step, and the objective
rebuild and initial-condition updates are counted in `solve_and_write`.

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
    open(path, "w") do io
        println(io, join(_TIMING_COLUMNS, ','))
        for row in rows
            println(io, join((row[Symbol(column)] for column in _TIMING_COLUMNS), ','))
        end
    end
    return path
end

function main(folder, day::Date)
    config = TOML.parsefile(joinpath(folder, "run.toml"))
    day_folder = joinpath(folder, string(day))
    package_root = dirname(dirname(pathof(AustralianElectricityMarkets)))
    actual_revision = try
        readchomp(`git -C $package_root rev-parse HEAD`)
    catch
        "unknown"
    end
    checkout_status = try
        readchomp(`git -C $package_root status --porcelain`)
    catch
        "unknown"
    end
    package_hashes = ReplayBatchSupport.snapshot_package_sources(package_root, joinpath(day_folder, "package_source"))
    time_series_in_memory = parse(Bool, config["time-series-in-memory"])
    provenance = Dict(
        "revision" => actual_revision, "supervisor_revision" => config["git_revision"],
        "time_series_in_memory" => time_series_in_memory,
        "checkout_status" => checkout_status, "package_source_hashes" => package_hashes, "optimization_level" => Int(Base.JLOptions().opt_level),
        "julia" => string(VERSION), "psi" => string(Base.pkgversion(PSI)),
        "highs_package" => string(Base.pkgversion(HiGHS)),
        "hdf5" => string(Base.pkgversion(HDF5)),
        "aem" => string(Base.pkgversion(AustralianElectricityMarkets)),
        "aem_simulations" => string(Base.pkgversion(AustralianElectricityMarketsSimulations)),
        "interval_time_zone" => "fixed AEST UTC+10", "intervention" => 0,
        "mip_rel_gap" => Dict(NEMDE_HIGHS_OPTIONS)["mip_rel_gap"], "mip_abs_gap" => Dict(NEMDE_HIGHS_OPTIONS)["mip_abs_gap"],
        "highs_options" => Dict{String, Any}(name => value for (name, value) in NEMDE_HIGHS_OPTIONS),
        "instrumentation" => "interval_timings.csv is read from PSI recorder events and optimizer stats after execute!; TimerOutputs trees in timers_*.toml overlap",
        "source_hashes" => Dict(name => bytes2hex(sha256(read(joinpath(@__DIR__, name)))) for name in readdir(@__DIR__) if endswith(name, ".jl")),
    )
    source_folder = joinpath(day_folder, "runner_source")
    mkpath(source_folder)
    for name in readdir(@__DIR__)
        any(ext -> endswith(name, ext), (".jl", ".py", ".md")) && cp(joinpath(@__DIR__, name), joinpath(source_folder, name))
    end
    cp(joinpath(dirname(dirname(dirname(Base.active_project()))), "Manifest.toml"), joinpath(day_folder, "Manifest.toml"))
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
            steps = ReplayBatchSupport.replay_steps(config, day)
            result = _replay_day(
                db, steps, day_folder;
                optimizer, time_series_in_memory, cache_size_mib = parse(Int, config["cache-size-mib"]), on_phase,
            )
            on_phase(:export)
            totals = save_day(day_folder, result)
            println("Completed $day: $totals")
            flush(stdout)
            open(joinpath(day_folder, "worker_outcome.toml"), "w") do io
                TOML.print(io, Dict(string(k) => v for (k, v) in pairs(totals)))
            end
        finally
            DuckDB.close(db.db)
        end
    catch err
        write(joinpath(day_folder, "worker_error.txt"), sprint(showerror, err, catch_backtrace()) * "\n")
        rethrow()
    end
    return
end

end
