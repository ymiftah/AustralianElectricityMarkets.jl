# Per-step interval timings from PSI's native recorder events and optimizer statistics. Read
# once `execute!` has returned; no PSI method is wrapped.

const _TIMING_COLUMNS = (
    "timestamp_utc", "interval_aest", "execution_count", "phase", "wall_s", "allocated_bytes",
    "gc_s", "compilation_s", "timed_solve_s", "pricing_s", "auxiliary_s", "schema_version",
)
const _TIMING_SCHEMA_VERSION = 2

_timing_seconds(from::DateTime, to::DateTime) = Dates.value(to - from) / 1000
_timing_nan(value) = ismissing(value) ? NaN : Float64(value)

# Each step has one `ProblemExecutionEvent` start and done. Parameter updates logged for the
# step's simulation time within that window end the `parameter_update` span; the rest of the
# window is `solve_and_write`.
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
    updates_events = Iterators.flatten(
        (
            PSI.list_simulation_events(PSI.ParameterUpdateEvent, folder),
            PSI.list_simulation_events(PSI.InitialConditionUpdateEvent, folder),
        )
    )
    for event in updates_events
        string(event.model_name) == name || continue
        push!(get!(Vector{DateTime}, updates, event.simulation_time), PSI.IS.get_timestamp(event))
    end

    offset = Dates.now() - Dates.now(Dates.UTC)
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
`solve_and_write` row per executed step, and returns its path. Fields the recorder does not
provide are written as `NaN`.
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
