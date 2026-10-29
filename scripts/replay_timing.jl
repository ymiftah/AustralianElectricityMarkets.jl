# Per-step interval timings from PSI's native recorder events and optimizer statistics. Read
# once `execute!` has returned; no PSI method is wrapped.

const _TIMING_COLUMNS = (
    "timestamp_utc", "interval_aest", "execution_count", "phase", "wall_s", "allocated_bytes",
    "gc_s", "compilation_s", "timed_solve_s", "pricing_s", "auxiliary_s", "schema_version",
)
const _TIMING_SCHEMA_VERSION = 2
const _QUARTER_HOUR_MS = 900_000

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
