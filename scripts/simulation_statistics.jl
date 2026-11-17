# Summarises saved NEM run batch runs: NEMDE errors, error distributions by category, timings and
# provenance. From the repository root:
#
#     julia --project=AustralianElectricityMarketsSimulations/test scripts/simulation_statistics.jl \
#         RUN [RUN...] [--output FOLDER] [--cache-windows N] [--hive FOLDER]
module SimulationStatistics

    using Dates
    using DuckDB
    using Printf
    using TOML

    export analyze, save_report, read_csv, distribution, error_distribution

    const REGIONS = ("NSW1", "QLD1", "SA1", "TAS1", "VIC1")
    const SERVICES = Tuple(side * speed for side in ("LOWER", "RAISE") for speed in ("1SEC", "6SEC", "60SEC", "5MIN", "REG"))
    # metric => (comparison table, field, entity columns, unit), in report order.
    const METRICS = [
        "dispatch_mw" => ("dispatch", "TOTALCLEARED", ("DUID",), "MW"),
        "energy_price" => ("prices", "ROP", ("REGIONID",), "\$/MWh"),
        "fcas_price" => ("fcas_prices", "ROP", ("REGIONID", "BIDTYPE"), "\$/MWh"),
        "interconnector_flow_mw" => ("interconnectors", "MWFLOW", ("INTERCONNECTORID",), "MW"),
        "interconnector_losses_mw" => ("interconnectors", "MWLOSSES", ("INTERCONNECTORID",), "MW"),
    ]
    # (Small constant tables are lookups rather than `Dict`s: each Dict type costs compile time in a fresh process.)
    metric_spec(metric) = last(METRICS[findfirst(p -> first(p) == metric, METRICS)])
    const PERCENTILES = (5, 25, 50, 75, 90, 95, 99)
    # Published ROP above \$300/MWh, from \$0 to \$300/MWh, below \$0/MWh.
    const PRICE_BANDS = ("above_300", "0_to_300", "below_0")
    # Mirrors MARKET_PRICE_CAP_BY_FINANCIAL_YEAR in src/system/penalties.jl, keyed by financial-year start.
    const MARKET_PRICE_CAP_BY_FINANCIAL_YEAR = [
        Date(2021, 7, 1) => 15_100.0, Date(2022, 7, 1) => 15_500.0, Date(2023, 7, 1) => 16_600.0,
        Date(2024, 7, 1) => 17_500.0, Date(2025, 7, 1) => 20_300.0, Date(2026, 7, 1) => 23_200.0,
    ]
    const MARKET_FLOOR_PRICE = -1000.0
    const VIOLATION_FAMILY = "generic_constraint"
    const NOTES = [
        "Errors are solved minus published; unqualified error percentiles are absolute errors.",
        "Energy prices compare ROP with ROP, not RRP. Market timestamps use fixed AEST UTC+10.",
        "Energy price tail: interval prices are unweighted regional means, not demand-weighted, because regional demand is not in the comparison files.",
        "Percentiles use linear interpolation between adjacent ordered observations.",
        "Accuracy summaries use completed days only. Partial and failed timing prefixes remain visible.",
        "Duplicate comparison keys are excluded entirely; missing values are never filled with zero.",
        "Pooled errors use the first completed attempt per day and compatible recorded provenance; exclusions are listed.",
        "Over-constrained intervals (generic-constraint violation with a price at or above MPC, at or below the floor) are flagged; the excluding pool drops all their rows.",
        "Dispatch/interconnector expected entity inventories are inferred from exports; absent entities cannot be certified complete.",
        "OPTIMAL is not an independent feasibility audit. Full numerical-audit coverage is not established by this report.",
        "Solve-wrapper time contains MIP, pricing and auxiliary work. Nested timings must not be added to parents.",
        "Compilation/GC are included in measured wall time and cover instrumented calls only. Allocations are traffic, not retained RAM.",
        "Cold/refill cohorts infer the configured cache-window pattern; they are not a measured IO attribution.",
        "Summed worker times across parallel runs are not elapsed host wall time.",
    ]
    # Schema 1 wrote solve_impl and result_write rows. Schema 2 writes one solve_and_write row per step,
    # whose span also covers the result write, the native state update and the warm start.
    const SOLVER_PHASES = ("solve_impl", "solve_and_write")
    const WRITE_PHASES = ("result_write", "solve_and_write")

    # A CSV record or report row: column names in order, values of any type.
    const Row = Vector{Pair{String, Any}}

    field(row, key, default = nothing) = (i = findfirst(p -> first(p) == key, row); isnothing(i) ? default : last(row[i]))
    haskey_row(row, key) = any(p -> first(p) == key, row)

    # A finite Float64 from a number or a string, else `nothing`.
    function number(value)
        x = value isa Real ? Float64(value) : value isa AbstractString ? tryparse(Float64, strip(value)) : nothing
        return !isnothing(x) && isfinite(x) ? x : nothing
    end

    # Splits CSV text into records of fields, honouring quoted fields; throws ArgumentError on a malformed quote.
    function _csv_records(text::AbstractString)
        records, record, buf = Vector{Vector{String}}(), String[], IOBuffer()
        quoted, after_quote, i, chars = false, false, 1, codeunits(text)
        while i <= length(chars)
            c = Char(chars[i])
            if quoted
                if c == '"'
                    if i < length(chars) && chars[i + 1] == UInt8('"')
                        write(buf, '"'); i += 1
                    else
                        quoted, after_quote = false, true
                    end
                else
                    write(buf, chars[i])
                end
            elseif c == '"'
                position(buf) == 0 && !after_quote || throw(ArgumentError("unexpected quote in field"))
                quoted = true
            elseif c == ','
                push!(record, String(take!(buf))); after_quote = false
            elseif c == '\n' || c == '\r'
                c == '\r' && i < length(chars) && chars[i + 1] == UInt8('\n') && (i += 1)
                push!(record, String(take!(buf))); after_quote = false
                (length(record) == 1 && isempty(record[1])) || push!(records, record)
                record = String[]
            else
                after_quote && throw(ArgumentError("text after a closing quote"))
                write(buf, chars[i])
            end
            i += 1
        end
        quoted && throw(ArgumentError("unterminated quoted field"))
        (position(buf) > 0 || !isempty(record)) && (push!(record, String(take!(buf))); push!(records, record))
        return records
    end

    """
        read_csv(path, warnings) -> Vector{Row}

    Reads a CSV snapshot as rows of `column => String` pairs, omitting an incomplete trailing record left by an
    active writer and malformed rows, each with a warning pushed to `warnings`. A missing file reads as no rows.

    # Arguments
    - `path`: the CSV file.
    - `warnings`: the `Vector{String}` that collects warnings.

    # Returns
    A `Vector{Row}`.
    """
    function read_csv(path, warnings)
        isfile(path) || return Row[]
        text = read(path, String)
        if !isempty(text) && !endswith(text, "\n")
            push!(warnings, "Incomplete trailing CSV record ignored: $path")
            cut = findlast('\n', text)
            text = isnothing(cut) ? "" : text[1:cut]
        end
        records = try
            _csv_records(text)
        catch err
            push!(warnings, "Incomplete/malformed CSV snapshot: $path: $(sprint(showerror, err))")
            return Row[]
        end
        isempty(records) && return Row[]
        header, rows = records[1], Row[]
        for record in records[2:end]
            if length(record) != length(header)
                push!(warnings, "Malformed CSV row ignored: $path")
                continue
            end
            push!(rows, Row([h => v for (h, v) in zip(header, record)]))
        end
        return rows
    end

    function read_toml(path, warnings)
        isfile(path) || return Dict{String, Any}()
        data = TOML.tryparsefile(path)
        if data isa TOML.ParserError
            push!(warnings, "Unreadable TOML snapshot: $path: $(sprint(showerror, data))")
            return Dict{String, Any}()
        end
        return data
    end

    function quantile_sorted(ordered, p)
        index = (length(ordered) - 1) * p
        lower = floor(Int, index)
        fraction = index - lower
        return ordered[lower + 1] * (1 - fraction) + ordered[min(lower + 2, length(ordered))] * fraction
    end

    """
        distribution(values) -> Dict{String, Any}

    The count, total, minimum, mean, maximum and percentiles of the finite values of `values`; `nothing`
    entries are ignored.

    # Returns
    A `Dict` with `"n"`, `"total_s"`, `"min"`, `"mean"`, `"max"` and `"p5"` to `"p99"`; only `"n" => 0` when no value is finite.
    """
    function distribution(values)
        ordered = sort!(Float64[v for v in values if !isnothing(v) && isfinite(v)])
        isempty(ordered) && return Dict{String, Any}("n" => 0)
        total = sum(ordered)
        out = Dict{String, Any}("n" => length(ordered), "total_s" => total, "min" => first(ordered), "mean" => total / length(ordered), "max" => last(ordered))
        for p in PERCENTILES
            out["p$p"] = quantile_sorted(ordered, p / 100)
        end
        return out
    end

    """
        error_distribution(errors) -> Dict{String, Any}

    The absolute-error distribution of signed `errors` (MAE, percentiles, maximum) with the signed bias, RMSE,
    signed 5th and 95th percentiles and the share within 1 unit.

    # Returns
    A `Dict`; only `"n" => 0` for no errors.
    """
    function error_distribution(errors)
        isempty(errors) && return Dict{String, Any}("n" => 0)
        out = distribution(abs.(errors))
        delete!(out, "total_s")
        out["mae"] = pop!(out, "mean")
        ordered = sort(errors)
        n = length(errors)
        out["bias"] = sum(errors) / n
        out["rmse"] = sqrt(sum(abs2, errors) / n)
        out["signed_p5"] = quantile_sorted(ordered, 0.05)
        out["signed_p95"] = quantile_sorted(ordered, 0.95)
        out["within_1_pct"] = 100 * count(e -> abs(e) <= 1, errors) / n
        return out
    end

    expected_times(day) = Set(string(DateTime(Date(day)) + Hour(4) + Minute(5) * (k + 1)) for k in 0:287)

    # The ISO AEST string of a timestamp, converting an offset or `Z` to UTC+10, or `nothing` when unparseable.
    const NORMALIZED = Dict{String, Union{Nothing, String}}()
    normalize_timestamp(value) = value isa AbstractString ? get!(() -> _normalize_timestamp(value), NORMALIZED, String(value)) : nothing

    function _normalize_timestamp(value)
        text = replace(strip(value), ' ' => 'T')
        m = match(r"^(.*?)(Z|[+-]\d{2}:\d{2})$", text)
        try
            isnothing(m) && return string(DateTime(text))
            z = m.captures[2]
            offset = z == "Z" ? Minute(0) : Minute((z[1] == '-' ? -1 : 1) * (60 * parse(Int, z[2:3]) + parse(Int, z[5:6])))
            return string(DateTime(m.captures[1]) - offset + Hour(10))
        catch
            return nothing
        end
    end

    """
        compare_day(folder, metric, warnings; flagged = Set{String}(), rows) -> (summary, errors, kept, by_entity, pairs)

    Compares one day's solved and published values of `metric`: duplicate keys and rows outside the trading
    day are counted and excluded, missing values are never filled. `kept` leaves out the intervals in
    `flagged`, `by_entity` maps each entity to its errors, and `pairs` lists the paired
    `(interval, published, solved)` of the energy price metric. `rows` are the comparison rows when already read.

    # Returns
    The summary `Dict`, the errors, the kept errors, the per-entity errors and the energy price pairs.
    """
    function compare_day(folder, metric, warnings; flagged = Set{String}(), rows = read_csv(joinpath(folder, "comparison_$(metric_spec(metric)[1]).csv"), warnings))
        table, fieldname, dimensions, unit = metric_spec(metric)
        path = joinpath(folder, "comparison_$table.csv")
        valid = expected_times(basename(folder))
        unique = Dict{Tuple{String, String}, Tuple{Any, Any}}()
        order = Tuple{String, String}[]
        duplicates = Set{Tuple{String, String}}()
        groups = Dict{String, Dict{Symbol, Any}}()
        group!(name) = get!(() -> Dict{Symbol, Any}(:errors => Float64[], :rows => 0, :missing => 0, :times => Set{String}()), groups, name)
        metric == "energy_price" && foreach(group!, REGIONS)
        metric == "fcas_price" && foreach(r -> foreach(s -> group!("$r|$s"), SERVICES), REGIONS)
        counts = Dict(k => 0 for k in ("rows", "out_of_day_rows", "invalid_entity_rows", "missing_or_nonfinite", "missing_nonzero_published"))
        published_key, solved_key = fieldname * "_published", fieldname * "_solved"
        for row in rows
            counts["rows"] += 1
            timestamp = normalize_timestamp(field(row, "SETTLEMENTDATE"))
            if isnothing(timestamp) || !(timestamp in valid)
                counts["out_of_day_rows"] += 1
                continue
            end
            if any(k -> isempty(something(field(row, k), "")), dimensions)
                counts["invalid_entity_rows"] += 1
                continue
            end
            key = (timestamp, join((field(row, k) for k in dimensions), "|"))
            if haskey(unique, key)
                push!(duplicates, key)
            else
                unique[key] = (number(field(row, published_key)), number(field(row, solved_key)))
                push!(order, key)
            end
        end
        errors, kept, pairs = Float64[], Float64[], Tuple{String, Float64, Float64}[]
        worst = Tuple{Float64, String, String, Float64, Float64, Float64}[]
        for key in order
            timestamp, name = key
            published, solved = unique[key]
            item = group!(name)
            item[:rows] += 1
            key in duplicates && continue
            if isnothing(published) || isnothing(solved)
                item[:missing] += 1
                counts["missing_or_nonfinite"] += 1
                !isnothing(published) && published != 0 && (counts["missing_nonzero_published"] += 1)
                continue
            end
            e = solved - published
            push!(errors, e)
            timestamp in flagged || push!(kept, e)
            push!(item[:errors], e)
            push!(item[:times], timestamp)
            metric == "energy_price" && push!(pairs, (timestamp, published, solved))
            # Running top ten by (|error|, interval, entity).
            if length(worst) < 10 || abs(e) >= first(last(worst))
                candidate = (abs(e), timestamp, name, published, solved, e)
                insert!(worst, searchsortedfirst(worst, candidate; rev = true), candidate)
                length(worst) > 10 && pop!(worst)
            end
        end
        summary = Dict{String, Any}(
            counts..., "duplicate_keys" => length(duplicates), "file_present" => isfile(path), "unit" => unit,
            "errors" => error_distribution(errors),
            "groups" => Dict{String, Any}(
                name => merge(
                    error_distribution(item[:errors]), Dict{String, Any}(
                        "rows" => item[:rows], "missing" => item[:missing], "paired_intervals" => length(item[:times]), "expected_intervals" => 288,
                    ),
                ) for (name, item) in groups
            ),
            "worst" => [
                Row(["absolute_error" => w[1], "interval_aest" => w[2], "entity" => w[3], "published" => w[4], "solved" => w[5], "error" => w[6]])
                    for w in worst
            ],
        )
        by_entity = Dict(name => item[:errors] for (name, item) in groups)
        return summary, errors, kept, by_entity, pairs
    end

    financial_year_start(t::DateTime) = Date(month(t) >= 7 ? year(t) : year(t) - 1, 7, 1)

    """
        over_constrained_intervals(folder, warnings) -> (rows, flagged)

    The price rows of a day that share an interval with a generic-constraint violation and an energy ROP at or
    above the Market Price Cap or at or below the floor, or an FCAS ROP at or above the cap, with the set of
    those interval timestamps.
    """
    function over_constrained_intervals(folder, warnings; read = f -> read_csv(joinpath(folder, f), warnings))
        violated = Dict{String, Set{String}}()
        isfile(joinpath(folder, "constraint_violations.csv")) || push!(warnings, "Missing constraint violations; no intervals flagged: $folder")
        for row in read("constraint_violations.csv")
            timestamp = normalize_timestamp(field(row, "DateTime"))
            field(row, "family") == VIOLATION_FAMILY && !isnothing(timestamp) && push!(get!(Set{String}, violated, timestamp), something(field(row, "name"), ""))
        end
        rows, flagged, missing_years = Row[], Set{String}(), Set{Date}()
        for (table, fcas) in (("comparison_prices.csv", false), ("comparison_fcas_prices.csv", true))
            for row in read(table)
                timestamp = normalize_timestamp(field(row, "SETTLEMENTDATE"))
                solved = number(field(row, "ROP_solved"))
                (isnothing(timestamp) || !haskey(violated, timestamp) || isnothing(solved)) && continue
                trigger = if !fcas && solved <= MARKET_FLOOR_PRICE
                    "energy_low"
                else
                    start = financial_year_start(DateTime(timestamp))
                    cap = (i = findfirst(p -> first(p) == start, MARKET_PRICE_CAP_BY_FINANCIAL_YEAR); isnothing(i) ? nothing : last(MARKET_PRICE_CAP_BY_FINANCIAL_YEAR[i]))
                    if isnothing(cap)
                        push!(missing_years, start)
                        continue
                    end
                    solved < cap && continue
                    fcas ? "fcas_high" : "energy_high"
                end
                entity = something(field(row, "REGIONID"), "") * (fcas ? "|" * something(field(row, "BIDTYPE"), "") : "")
                push!(flagged, timestamp)
                push!(
                    rows, Row(
                        [
                            "day" => basename(folder), "interval" => timestamp, "trigger" => trigger, "entity" => entity,
                            "published" => number(field(row, "ROP_published")), "solved" => solved,
                            "constraints" => join(sort!(collect(violated[timestamp])), ";"),
                        ]
                    ),
                )
            end
        end
        for start in sort!(collect(missing_years))
            push!(warnings, "No market price cap for financial year starting $start; its intervals not flagged: $folder")
        end
        return rows, flagged
    end

    function native_snapshots(folder, warnings)
        snapshots, states = Row[], Tuple{Any, Float64}[]
        paths = filter(f -> occursin(r"^timers_.*_chunk_\d+\.toml$", f), readdir(folder))
        sort!(paths; by = f -> parse(Int, match(r"_(\d+)\.toml$", f).captures[1]))
        for name in paths
            data = read_toml(joinpath(folder, name), warnings)
            function walk(node, parts)
                isempty(parts) || push!(
                    snapshots, Row(
                        [
                            "file" => name, "timer" => join(parts, "/"), "calls" => get(node, "n_calls", nothing),
                            "time_s" => something(number(get(node, "time_ns", nothing)), 0.0) / 1.0e9,
                        ]
                    ),
                )
                inner = get(node, "inner_timers", Dict{String, Any}())
                for child in sort!(collect(keys(inner)))
                    walk(inner[child], [parts; child])
                end
                return
            end
            walk(data, String[])
            if startswith(name, "timers_execute")
                execute = get(get(data, "inner_timers", Dict()), "Execute Simulation", Dict())
                dispatch = get(get(execute, "inner_timers", Dict()), "Execute dispatch", Dict())
                state = get(get(dispatch, "inner_timers", Dict()), "Update State", nothing)
                isnothing(state) || push!(states, (get(execute, "n_calls", nothing), something(number(get(state, "time_ns", nothing)), 0.0) / 1.0e9))
            end
        end
        total = nothing
        if length(states) == 1
            total = states[1][2]
        elseif !isempty(states)
            calls = first.(states)
            if all(==(1), calls)
                total = sum(last.(states))
            elseif all(c -> c isa Integer, calls) && all(calls[i] < calls[i + 1] for i in 1:(length(calls) - 1))
                total = last(states)[2]
            else
                push!(warnings, "Ambiguous cumulative native timers; state total withheld: $folder")
            end
        end
        return snapshots, total
    end

    function timing_schema(row)
        haskey_row(row, "schema_version") || return 1
        v = field(row, "schema_version")
        v in ("1", "2") || throw(ArgumentError("Unsupported interval timing schema_version: $(repr(v))"))
        return parse(Int, v)
    end

    function single_timing_schema(schemas, folder)
        length(schemas) > 1 && throw(ArgumentError("Schema 1 and schema 2 interval timings cannot be pooled: $folder"))
        return isempty(schemas) ? nothing : first(schemas)
    end

    # The recorder's gc, compilation and allocation totals that `schema` measured: schema 1 the whole solve
    # wrapper, schema 2 `JuMP.optimize!` only.
    function instrumented_totals(schema, instrumented, optimizer)
        total(v) = sum(x for x in v if !isnothing(x); init = 0.0)
        keys_ = ("instrumented_gc_s", "instrumented_compilation_s", "instrumented_allocated_bytes", "optimize_gc_s", "optimize_allocated_bytes")
        out = Dict{String, Any}(k => nothing for k in keys_)
        if schema == 1
            out["instrumented_gc_s"] = total(get(instrumented, "gc_s", []))
            out["instrumented_compilation_s"] = total(get(instrumented, "compilation_s", []))
            out["instrumented_allocated_bytes"] = total(get(instrumented, "allocated_bytes", []))
        elseif schema == 2
            out["optimize_gc_s"] = total(get(optimizer, "gc_s", []))
            out["optimize_allocated_bytes"] = total(get(optimizer, "allocated_bytes", []))
        end
        return out
    end

    _files_named(folder, name) = sort!([joinpath(d, f) for (d, _, fs) in walkdir(folder) for f in fs if f == name])

    function day_timing(folder, totals, cache_windows, warnings)
        series = Dict{String, Vector{Any}}()
        calls = Dict{String, Vector{Row}}()
        instrumented, optimizer = Dict{String, Vector{Any}}(), Dict{String, Vector{Any}}()
        seen, schemas, written = Set{Tuple}(), Set{Int}(), 0
        add!(d, k, v) = push!(get!(() -> Any[], d, k), v)
        for path in _files_named(folder, "interval_timings.csv")
            first_update = true
            for row in read_csv(path, warnings)
                phase = field(row, "phase")
                schema = timing_schema(row)
                push!(schemas, schema)
                key = (path, phase, field(row, "execution_count"), field(row, "interval_aest"))
                if key in seen
                    push!(warnings, "Duplicate interval timing omitted: $key")
                    continue
                end
                push!(seen, key)
                wall = number(field(row, "wall_s"))
                (isnothing(wall) || wall < 0) && continue
                add!(series, phase, wall)
                push!(get!(() -> Row[], calls, phase), Row(["interval_aest" => field(row, "interval_aest"), "wall_s" => wall]))
                written += phase in WRITE_PHASES
                for f in ("gc_s", "compilation_s", "allocated_bytes")
                    value = number(field(row, f))
                    add!(instrumented, f, value)
                    schema == 2 && phase == "solve_and_write" && f != "compilation_s" && add!(optimizer, f, value)
                end
                if phase in SOLVER_PHASES
                    children = Any[]
                    for (f, label) in (("timed_solve_s", "mip"), ("pricing_s", "pricing"), ("auxiliary_s", "auxiliary"))
                        value = number(field(row, f))
                        add!(series, label, value)
                        push!(children, value)
                        isnothing(value) || push!(get!(() -> Row[], calls, label), Row(["interval_aest" => field(row, "interval_aest"), "wall_s" => value]))
                    end
                    all(!isnothing, children) && add!(series, schema == 1 ? "solve_wrapper_residual" : "solve_and_write_residual", wall - sum(children))
                end
                if phase == "parameter_update"
                    n = number(field(row, "execution_count"))
                    cohort = first_update ? "cold" : !isnothing(n) && mod(n, cache_windows) == 1 ? "refill_candidate" : "ordinary"
                    add!(series, "updates_" * cohort, wall)
                    first_update = false
                end
            end
        end
        schema = single_timing_schema(schemas, folder)
        native, state = native_snapshots(folder, warnings)
        execute = number(field(totals, "execute_s"))
        measured = sum((v for p in (schema == 1 ? ("parameter_update", "solve_impl", "result_write") : schema == 2 ? ("parameter_update", "solve_and_write") : ()) for v in get(series, p, []) if !isnothing(v)); init = 0.0)
        # The native state update sits inside schema 2's solve_and_write span, so it is not subtracted again.
        unattributed = isnothing(execute) || isnothing(schema) ? nothing : execute - measured - (schema == 1 ? something(state, 0.0) : 0.0)
        result = Dict{String, Any}(
            "timing_schema" => schema, "series" => Dict{String, Any}(k => distribution(v) for (k, v) in series),
            instrumented_totals(schema, instrumented, optimizer)..., "native_state_s" => state, "native_snapshots" => native,
            "execution_unattributed_s" => unattributed,
            "slowest_calls" => Dict{String, Any}(p => first(sort(rows; by = r -> field(r, "wall_s"), rev = true), 10) for (p, rows) in calls),
            "written_intervals" => written,
        )
        !isnothing(unattributed) && unattributed < -0.1 && push!(warnings, "Negative execution residual; timer boundaries require review: $folder")
        wall = number(field(totals, "elapsed_s"))
        parts = [number(field(totals, f)) for f in ("system_build_s", "model_build_s", "execute_s", "compare_s")]
        result["outside_build_execute_compare_s"] = !isnothing(wall) && all(!isnothing, parts) ? wall - sum(parts) : nothing
        return result
    end

    function provenance_signature(provenance)
        keys_ = ("revision", "psi", "aem", "aem_simulations", "hdf5", "julia", "optimization_level", "intervention", "mip_rel_gap", "mip_abs_gap", "package_source_hashes", "closed_loop")
        return to_json(Dict{String, Any}(k => get(provenance, k, nothing) for k in keys_); indent = 0)
    end

    # The (region, dispatch type, schedule type) of each DUID registered on `day` in the cache's DUDETAILSUMMARY.
    function unit_categories(hive, day)
        db = DuckDB.DB()
        try
            glob = joinpath(hive, "DUDETAILSUMMARY", "*", "*.parquet")
            result = DuckDB.execute(
                db, """
                SELECT DUID, arg_max(REGIONID, START_DATE), arg_max(DISPATCHTYPE, START_DATE), arg_max(SCHEDULE_TYPE, START_DATE)
                FROM read_parquet('$glob') WHERE START_DATE <= DATE '$day' GROUP BY DUID
                """,
            )
            return Dict(String(r[1]) => (String(something(r[2], "UNKNOWN")), String(something(r[3], "UNKNOWN")), String(something(r[4], "UNKNOWN"))) for r in result)
        finally
            DBInterface.close!(db)
        end
    end

    _block(timestamp) = (h = hour(DateTime(timestamp) - Minute(5)); b = 4 * div(h, 4); @sprintf("%02d:00-%02d:00", b, b + 4))

    # The category labels of one entity of `metric`: `kind => label` pairs.
    function _categories(metric, entity, units)
        if metric == "fcas_price"
            region, service = split(entity, "|")
            return ["service" => service, "region" => region, "direction" => startswith(service, "RAISE") ? "RAISE" : "LOWER"]
        elseif metric == "energy_price"
            return ["region" => entity]
        elseif metric in ("interconnector_flow_mw", "interconnector_losses_mw")
            return ["interconnector" => entity]
        elseif metric == "dispatch_mw" && !isnothing(units)
            region, dispatch, schedule = get(units, entity, ("UNKNOWN", "UNKNOWN", "UNKNOWN"))
            return ["region" => region, "dispatch type" => dispatch, "schedule type" => schedule, "dispatch / schedule type" => "$dispatch / $schedule"]
        end
        return Pair{String, String}[]
    end

    function signed_summary(v)
        isempty(v) && return Dict{String, Any}("n" => 0)
        ordered = sort(v)
        return Dict{String, Any}(
            "n" => length(v), "mean" => sum(v) / length(v), "median" => quantile_sorted(ordered, 0.5),
            "p5" => quantile_sorted(ordered, 0.05), "p95" => quantile_sorted(ordered, 0.95),
        )
    end

    # The energy price tail of paired (interval, published, solved) ROPs: signed errors, errors by published-price
    # band and the interval prices (unweighted regional means) ranked by published price.
    function price_tail(pairs)
        sums = Dict{String, Vector{Float64}}()
        for (t, p, s) in pairs
            acc = get!(() -> zeros(3), sums, t)
            acc[1] += p
            acc[2] += s
            acc[3] += 1
        end
        duration = sort!([(t, a[1] / a[3], a[2] / a[3]) for (t, a) in sums]; by = d -> (-d[2], d[1]))
        band(p) = p > 300 ? 1 : p >= 0 ? 2 : 3
        bands = Dict{String, Any}()
        for (i, name) in enumerate(PRICE_BANDS)
            errors = Float64[s - p for (_, p, s) in pairs if band(p) == i]
            bands[name] = error_distribution(errors)
            bands[name]["share_pct"] = 100 * length(errors) / max(length(pairs), 1)
        end
        tail = Dict{String, Any}(
            "weighting" => "unweighted mean of the regional ROPs paired in each interval; regional demand is not in the comparison files",
            "regional_signed" => signed_summary(Float64[s - p for (_, p, s) in pairs]),
            "interval_signed" => signed_summary(Float64[s - p for (_, p, s) in duration]), "bands" => bands,
        )
        return tail, duration
    end

    """
        analyze(runs; cache_windows = 24, hive = nothing) -> Dict{String, Any}

    Summarises the run batch runs in `runs`, in pooling priority order: per-day comparisons and timings,
    pooled NEMDE errors over the first compatible completed attempt per day (with and without over-constrained
    intervals), error distributions by category, and warnings. With `hive`, dispatch errors are also grouped by
    the units' region, dispatch type and schedule type from the cache's `DUDETAILSUMMARY`.

    # Arguments
    - `runs`: the run output folders.
    - `cache_windows`: the window count used only to infer parameter-update cohorts.
    - `hive`: the NEMWEB cache folder, or `nothing`.

    # Returns
    The result `Dict`, serialisable by [`save_report`](@ref).
    """
    function analyze(runs; cache_windows = 24, hive = nothing)
        warnings = String[]
        result = Dict{String, Any}(
            "generated_utc" => string(now(UTC)) * "Z", "notes" => NOTES, "warnings" => warnings, "runs" => Any[], "days" => Any[], "cache_windows" => cache_windows,
        )
        pools, kept_pools = Dict{String, Vector{Float64}}(), Dict{String, Vector{Float64}}()
        categories = Dict{String, Dict{String, Dict{String, Vector{Float64}}}}()
        flagged_rows, selected, signature = Row[], Set{String}(), nothing
        tail_pairs = Tuple{String, Float64, Float64}[]
        for root in unique(realpath.(abspath.(runs)))
            isdir(root) || throw(ArgumentError("Run directory does not exist: $root"))
            totals = Dict(field(r, "trading_day") => r for r in read_csv(joinpath(root, "days.csv"), warnings) if field(r, "status") == "completed")
            failures = read_csv(joinpath(root, "failures.csv"), warnings)
            failed = Set(field(r, "trading_day") for r in failures)
            phases = Dict{String, Vector{Row}}()
            phase_rows = read_csv(joinpath(root, "phases.csv"), warnings)
            for (i, row) in enumerate(phase_rows)
                start = number(field(row, "elapsed_s"))
                stop = i < length(phase_rows) ? number(field(phase_rows[i + 1], "elapsed_s")) : nothing
                push!(row, "observed_span_s" => isnothing(start) || isnothing(stop) ? nothing : stop - start, "span_complete" => !isnothing(stop))
                push!(get!(() -> Row[], phases, field(row, "trading_day")), row)
            end
            push!(
                result["runs"], Dict{String, Any}(
                    "path" => root, "status" => read_toml(joinpath(root, "status.toml"), warnings), "config" => read_toml(joinpath(root, "run.toml"), warnings),
                    "outcome" => read_toml(joinpath(root, "outcome.toml"), warnings), "failures" => failures,
                    "completed_days" => length(totals), "failed_days" => length(failures),
                ),
            )
            for day in sort!(readdir(root))
                folder = joinpath(root, day)
                (isdir(folder) && occursin(r"^\d{4}-\d{2}-\d{2}$", day)) || continue
                try
                    Date(day)
                catch
                    push!(warnings, "Invalid day directory ignored: $folder")
                    continue
                end
                status = haskey(totals, day) ? "completed" : day in failed ? "failed" : "in_progress"
                provenance = read_toml(joinpath(folder, "provenance.toml"), warnings)
                day_totals = get(totals, day, Row())
                item = Dict{String, Any}(
                    "run" => root, "day" => day, "status" => status, "provenance" => provenance,
                    "totals" => Row([k => (k in ("trading_day", "status") ? v : number(v)) for (k, v) in day_totals]),
                    "phase_boundaries" => get(phases, day, Row[]), "timing" => day_timing(folder, day_totals, cache_windows, warnings),
                    "comparisons" => Dict{String, Any}(), "pooled" => false,
                )
                if status == "completed"
                    current = provenance_signature(provenance)
                    eligible = !(day in selected) && (isnothing(signature) || signature == current)
                    if day in selected
                        push!(warnings, "Completed-day overlap excluded from pooled errors: $folder")
                    elseif !isnothing(signature) && signature != current
                        push!(warnings, "Different provenance excluded from pooled errors: $folder")
                    end
                    if eligible
                        signature = current
                        push!(selected, day)
                        item["pooled"] = true
                    end
                    cache = Dict{String, Vector{Row}}()
                    read = f -> get!(() -> read_csv(joinpath(folder, f), warnings), cache, f)
                    day_flags, flagged = over_constrained_intervals(folder, warnings; read)
                    append!(flagged_rows, [Row(["run" => root; r]) for r in day_flags])
                    units = eligible && !isnothing(hive) ? unit_categories(hive, day) : nothing
                    for (metric, _) in METRICS
                        table = metric_spec(metric)[1]
                        comparison, errors, kept, by_entity, pairs = compare_day(folder, metric, warnings; flagged, rows = read("comparison_$table.csv"))
                        item["comparisons"][metric] = comparison
                        comparison["file_present"] || push!(warnings, "Missing completed comparison: $folder: $metric")
                        eligible || continue
                        append!(tail_pairs, pairs)
                        append!(get!(() -> Float64[], pools, metric), errors)
                        append!(get!(() -> Float64[], kept_pools, metric), kept)
                        kinds = get!(() -> Dict{String, Dict{String, Vector{Float64}}}(), categories, metric)
                        for (entity, values) in by_entity, (kind, label) in _categories(metric, entity, units)
                            append!(get!(() -> Float64[], get!(() -> Dict{String, Vector{Float64}}(), kinds, kind), label), values)
                        end
                    end
                    if eligible
                        # Energy prices by four-hour block of the interval start.
                        blocks = get!(() -> Dict{String, Vector{Float64}}(), get!(() -> Dict{String, Dict{String, Vector{Float64}}}(), categories, "energy_price"), "time of day")
                        for row in read("comparison_prices.csv")
                            p, s, t = number(field(row, "ROP_published")), number(field(row, "ROP_solved")), normalize_timestamp(field(row, "SETTLEMENTDATE"))
                            (isnothing(p) || isnothing(s) || isnothing(t)) && continue
                            push!(get!(() -> Float64[], blocks, _block(t)), s - p)
                        end
                    end
                end
                push!(result["days"], item)
            end
        end
        schemas = Set(d["timing"]["timing_schema"] for d in result["days"] if !isnothing(d["timing"]["timing_schema"]))
        length(schemas) > 1 && throw(ArgumentError("Schema 1 and schema 2 interval timings cannot be pooled across days: $(sort!(collect(schemas)))"))
        result["pooled"] = Dict{String, Any}(m => error_distribution(v) for (m, v) in pools)
        result["pooled_excluding_over_constrained"] = Dict{String, Any}(m => error_distribution(v) for (m, v) in kept_pools)
        result["categories"] = Dict{String, Any}(m => Dict{String, Any}(k => Dict{String, Any}(l => error_distribution(v) for (l, v) in labels) for (k, labels) in kinds) for (m, kinds) in categories)
        result["over_constrained_intervals"] = flagged_rows
        result["price_tail"], duration = price_tail(tail_pairs)
        result["price_duration"] = [Row(["position" => i, "interval" => t, "published" => p, "solved" => s]) for (i, (t, p, s)) in enumerate(duration)]
        result["unique_completed_days"] = length(Set(d["day"] for d in result["days"] if d["status"] == "completed"))
        result["pooled_completed_days"] = length(selected)
        result["unique_written_intervals"] = length(
            Set(
                (d["day"], field(r, "interval_aest")) for d in result["days"] for path in _files_named(joinpath(d["run"], d["day"]), "interval_timings.csv")
                    for r in read_csv(path, warnings) if field(r, "phase") in WRITE_PHASES && !isempty(something(field(r, "interval_aest"), ""))
            ),
        )
        return result
    end

    # --- Output ---------------------------------------------------------------------------------------

    _json_string(s) = "\"" * replace(s, "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t") * "\""

    # The key/value pairs of a JSON object, dictionaries sorted by key; one compiled method for all dictionary types.
    function _json_items(@nospecialize(x))
        x isa Row && return x
        return sort!(Pair{String, Any}[string(k) => v for (k, v) in x]; by = first)
    end

    function _json(io, @nospecialize(x), indent, level)
        pad(l) = indent > 0 ? "\n" * " "^(indent * l) : ""
        sep = indent > 0 ? ": " : ":"
        if isnothing(x) || (x isa AbstractFloat && !isfinite(x))
            print(io, "null")
        elseif x isa Bool
            print(io, x ? "true" : "false")
        elseif x isa Real
            print(io, x isa Integer ? string(x) : repr(Float64(x)))
        elseif x isa AbstractString || x isa Symbol || x isa Date || x isa DateTime
            print(io, _json_string(string(x)))
        elseif x isa AbstractDict || x isa Row
            items = _json_items(x)
            isempty(items) && return print(io, "{}")
            print(io, "{")
            for (i, (k, v)) in enumerate(items)
                print(io, i > 1 ? "," : "", pad(level + 1), _json_string(string(k)), sep)
                _json(io, v, indent, level + 1)
            end
            print(io, pad(level), "}")
        elseif x isa AbstractVector || x isa Tuple || x isa AbstractSet
            isempty(x) && return print(io, "[]")
            print(io, "[")
            for (i, v) in enumerate(x)
                print(io, i > 1 ? "," : "", pad(level + 1))
                _json(io, v, indent, level + 1)
            end
            print(io, pad(level), "]")
        else
            print(io, _json_string(string(x)))
        end
        return
    end

    to_json(x; indent = 2) = sprint(io -> _json(io, x, indent, 0))

    _csv_cell(v) = isnothing(v) ? "" : (s = string(v); occursin(r"[,\"\n\r]", s) ? "\"" * replace(s, "\"" => "\"\"") * "\"" : s)

    function write_csv(path, rows)
        isempty(rows) && return write(path, "")
        columns = unique(first(p) for r in rows for p in r)
        open(path, "w") do io
            println(io, join(_csv_cell.(columns), ","))
            for r in rows
                println(io, join((_csv_cell(field(r, c)) for c in columns), ","))
            end
        end
        return
    end

    format_value(v) = isnothing(v) ? "-" : v isa Bool ? string(Int(v)) : v isa Real ? @sprintf("%.6g", v) : string(v)

    function markdown_table(headers, rows)
        lines = ["| " * join(headers, " | ") * " |", "| " * join(fill("---", length(headers)), " | ") * " |"]
        for row in rows
            push!(lines, "| " * join((replace(format_value(v), "|" => "/") for v in row), " | ") * " |")
        end
        return join(lines, "\n")
    end

    _get(d, k) = d isa Row ? field(d, k) : get(d, k, nothing)

    """
        save_report(result, output)

    Writes `report.md`, `statistics.json` and the CSV tables of [`analyze`](@ref)'s `result` into `output`.

    # Arguments
    - `result`: the result of [`analyze`](@ref).
    - `output`: the report folder, created when absent.

    # Returns
    `nothing`.
    """
    function save_report(result, output)
        mkpath(output)
        runtime, errors, groups, timings, worst, native, boundaries, slow = (Row[] for _ in 1:8)
        for day in result["days"]
            context = Row(["run" => day["run"], "day" => day["day"], "status" => day["status"]])
            timing = day["timing"]
            series = timing["series"]
            push!(
                runtime, Row(
                    [
                        context; day["totals"]; "timing_schema" => timing["timing_schema"]; "written_intervals" => timing["written_intervals"];
                        [p * "_s" => get(get(series, p, Dict()), "total_s", nothing) for p in ("parameter_update", "mip", "pricing", "auxiliary", "result_write", "solve_and_write")];
                        [k => timing[k] for k in ("native_state_s", "execution_unattributed_s", "outside_build_execute_compare_s", "instrumented_gc_s", "instrumented_compilation_s", "instrumented_allocated_bytes", "optimize_gc_s", "optimize_allocated_bytes")]
                    ]
                ),
            )
            for phase in sort!(collect(keys(series)))
                push!(timings, Row([context; "phase" => phase; sort!(collect(pairs(series[phase])); by = first)]))
            end
            append!(native, [Row([context; r]) for r in timing["native_snapshots"]])
            for phase in sort!(collect(keys(timing["slowest_calls"]))), r in timing["slowest_calls"][phase]
                push!(slow, Row([context; "phase" => phase; r]))
            end
            append!(boundaries, [Row([context; r]) for r in day["phase_boundaries"]])
            for (metric, _) in METRICS
                haskey(day["comparisons"], metric) || continue
                c = day["comparisons"][metric]
                push!(
                    errors, Row(
                        [
                            context; "metric" => metric; "unit" => c["unit"]; "pooled" => day["pooled"]; sort!(collect(pairs(c["errors"])); by = first);
                            [k => c[k] for k in ("rows", "missing_or_nonfinite", "missing_nonzero_published", "duplicate_keys", "out_of_day_rows")]
                        ]
                    ),
                )
                for entity in sort!(collect(keys(c["groups"])))
                    push!(groups, Row([context; "metric" => metric; "entity" => entity; "unit" => c["unit"]; sort!(collect(pairs(c["groups"][entity])); by = first)]))
                end
                append!(worst, [Row([context; "metric" => metric; "unit" => c["unit"]; r]) for r in c["worst"]])
            end
        end
        category_rows = Row[]
        for (metric, (_, _, _, unit)) in METRICS, kind in sort!(collect(keys(get(result["categories"], metric, Dict()))))
            labels = result["categories"][metric][kind]
            for label in sort!(collect(keys(labels)))
                push!(category_rows, Row(["metric" => metric; "unit" => unit; "category" => kind; "label" => label; sort!(collect(pairs(labels[label])); by = first)]))
            end
        end
        for (name, rows) in (
                "runtime.csv" => runtime, "errors.csv" => errors, "entity_errors.csv" => groups, "category_errors.csv" => category_rows,
                "timing_percentiles.csv" => timings, "worst_errors.csv" => worst, "native_timers.csv" => native,
                "phase_boundaries.csv" => boundaries, "slowest_intervals.csv" => slow, "over_constrained_intervals.csv" => result["over_constrained_intervals"],
                "price_duration.csv" => result["price_duration"],
            )
            write_csv(joinpath(output, name), rows)
        end
        write(joinpath(output, "statistics.json"), to_json(filter(p -> first(p) != "price_duration", result)) * "\n")
        stat(d, keys_) = [_get(d, k) for k in keys_]
        tail, duration = result["price_tail"], result["price_duration"]
        # The ten highest intervals and the top 1, 5, 10, 25 and 50 percent marks.
        extract = sort!(unique([1:min(10, length(duration)); [clamp(ceil(Int, length(duration) * q), 1, length(duration)) for q in (0.01, 0.05, 0.1, 0.25, 0.5)]]))
        isempty(duration) && empty!(extract)
        lines = String[
            "# Simulation statistics", "", "Snapshot: $(result["generated_utc"])", "",
            "Completed unique trading days: $(result["unique_completed_days"]); unique written interval identities: $(result["unique_written_intervals"]).", "",
            "## Runtime", "", "Seconds. Partial days have timing prefixes only. Repeated days remain separate worker attempts.", "",
            markdown_table(
                ["Run", "Day", "Status", "Wall", "Build system/model", "Updates", "MIP", "Pricing", "Writes", "Solve and write"],
                [
                    [
                        basename(field(r, "run")), field(r, "day"), field(r, "status"), field(r, "elapsed_s"),
                        isnothing(field(r, "elapsed_s")) ? nothing : something(field(r, "system_build_s"), 0.0) + something(field(r, "model_build_s"), 0.0),
                        stat(r, ("parameter_update_s", "mip_s", "pricing_s", "result_write_s", "solve_and_write_s"))...,
                    ] for r in runtime
                ],
            ),
            "", "## Timing distributions", "", "Seconds per instrumented call; nested phases are shown separately.", "",
            markdown_table(
                ["Day", "Phase/cohort", "n", "Total", "p5", "p25", "p50", "p75", "p90", "p95", "p99", "Max"],
                [[field(r, "day"); field(r, "phase"); stat(r, ("n", "total_s", "p5", "p25", "p50", "p75", "p90", "p95", "p99", "max"))] for r in timings if !(field(r, "phase") in ("solve_impl", "solve_and_write", "parameter_update"))],
            ),
            "", "## Completed-day NEMDE absolute errors", "",
            markdown_table(
                ["Day", "Metric", "Unit", "n", "MAE", "p5", "p50", "p95", "p99", "Max"],
                [[field(r, "day"); field(r, "metric"); field(r, "unit"); stat(r, ("n", "mae", "p5", "p50", "p95", "p99", "max"))] for r in errors],
            ),
            "", "## Pooled compatible unique-day errors", "",
            markdown_table(["Metric", "n", "MAE", "Bias", "p5", "p95", "p99", "Max"], [[m; stat(result["pooled"][m], ("n", "mae", "bias", "p5", "p95", "p99", "max"))] for (m, _) in METRICS if haskey(result["pooled"], m)]),
            "", "## Pooled errors excluding over-constrained intervals", "", "Same pool as above, with every row of a flagged interval removed.", "",
            markdown_table(
                ["Metric", "n", "MAE", "Bias", "p5", "p95", "p99", "Max"],
                [[m; stat(result["pooled_excluding_over_constrained"][m], ("n", "mae", "bias", "p5", "p95", "p99", "max"))] for (m, _) in METRICS if haskey(result["pooled_excluding_over_constrained"], m)],
            ),
            "", "## Energy price tail", "",
            "Pooled days; signed errors are solved minus published ROP in \$/MWh, comparable with nempy. Interval prices are the $(tail["weighting"]).", "",
            markdown_table(
                ["Series", "n", "Mean", "Median", "p5", "p95"],
                [[l; stat(tail[k], ("n", "mean", "median", "p5", "p95"))] for (l, k) in (("Regional ROP error", "regional_signed"), ("Interval price error", "interval_signed"))],
            ),
            "", "### Regional ROP error by published price band", "",
            markdown_table(
                ["Published ROP", "n", "Share %", "MAE", "RMSE", "Bias", "Signed p5", "Signed p95", "p99", "Max"],
                [[b; stat(tail["bands"][b], ("n", "share_pct", "mae", "rmse", "bias", "signed_p5", "signed_p95", "p99", "max"))] for b in PRICE_BANDS],
            ),
            "", "### Price-duration extract", "", "Ranked by published price, highest first; the full table is price_duration.csv.", "",
            markdown_table(["Position", "Interval", "Published", "Solved"], [stat(duration[i], ("position", "interval", "published", "solved")) for i in extract]),
            "", "## Error distributions by category", "",
            "Pooled days. Absolute errors except bias and the signed percentiles; within 1 is the share of cells within 1 unit.", "",
        ]
        for (metric, (_, _, _, unit)) in METRICS, kind in sort!(collect(keys(get(result["categories"], metric, Dict()))))
            labels = result["categories"][metric][kind]
            order = sort!(collect(keys(labels)); by = l -> kind == "time of day" ? l : -something(get(labels[l], "mae", nothing), -1.0))
            push!(lines, "### $metric by $kind ($unit)", "")
            push!(
                lines, markdown_table(
                    ["$kind", "n", "MAE", "RMSE", "Bias", "Within 1 %", "p50", "p90", "p95", "p99", "Max", "Signed p5", "Signed p95"],
                    [[l; stat(labels[l], ("n", "mae", "rmse", "bias", "within_1_pct", "p50", "p90", "p95", "p99", "max", "signed_p5", "signed_p95"))] for l in order],
                ), "",
            )
        end
        flagged = Set((field(r, "run"), field(r, "day"), field(r, "interval")) for r in result["over_constrained_intervals"])
        append!(
            lines, [
                "## Over-constrained intervals", "",
                "Flagged intervals: $(length(flagged)); rows are price triggers on intervals with a generic-constraint violation.", "",
                markdown_table(
                    ["Run", "Day", "Interval", "Trigger", "Entity", "Published", "Solved", "Violated constraints"],
                    [[basename(field(r, "run")); stat(r, ("day", "interval", "trigger", "entity", "published", "solved", "constraints"))] for r in result["over_constrained_intervals"]],
                ),
                "", "## Regional energy ROP errors", "", "Absolute errors in \$/MWh, with signed bias.", "",
                markdown_table(
                    ["Day", "Region", "Paired intervals", "MAE", "Bias", "p5", "p50", "p95", "p99", "Max"],
                    [[field(r, "day"); field(r, "entity"); stat(r, ("paired_intervals", "mae", "bias", "p5", "p50", "p95", "p99", "max"))] for r in groups if field(r, "metric") == "energy_price"],
                ),
                "", "## Unit outliers by daily MAE", "", "The twenty highest daily unit MAEs; all units are retained in entity_errors.csv.", "",
                markdown_table(
                    ["Day", "DUID", "Paired intervals", "MAE MW", "p95", "p99", "Max"],
                    [
                        [field(r, "day"); field(r, "entity"); stat(r, ("paired_intervals", "mae", "p95", "p99", "max"))]
                            for r in first(sort([r for r in groups if field(r, "metric") == "dispatch_mw"]; by = r -> something(field(r, "mae"), -1.0), rev = true), 20)
                    ],
                ),
                "", "## Completed and failed days", "",
            ],
        )
        for run in result["runs"]
            push!(lines, "- $(run["path"]): $(run["completed_days"]) completed / $(run["failed_days"]) failed days.")
            for f in run["failures"]
                push!(lines, "  - Failed $(field(f, "trading_day")); preserved error in statistics.json and the source run.")
            end
        end
        append!(lines, ["", "## Interpretation and coverage", "", ("- " * n for n in result["notes"])..., "", "## Snapshot warnings", "", ("- " * w for w in result["warnings"])...])
        isempty(result["warnings"]) && push!(lines, "No parser or pooling warnings.")
        push!(
            lines, "",
            "See timing_percentiles.csv for per-day phase/cohort distributions, entity_errors.csv for unit/region/service/link " *
                "coverage and percentiles, category_errors.csv for the category distributions, worst_errors.csv for outliers, " *
                "price_duration.csv for the ranked interval prices, native_timers.csv for unaggregated nested snapshots, slowest_intervals.csv for timing outliers, " *
                "and phase_boundaries.csv for loading/preflight/build/execute/compare/export boundaries and observed spans. " *
                "Boundary spans include framework overhead and must not be added to their internal timers.", "",
        )
        write(joinpath(output, "report.md"), join(lines, "\n"))
        return
    end

    const USAGE = """
    usage: simulation_statistics.jl RUN [RUN...] [--output FOLDER] [--cache-windows N] [--hive FOLDER]

      RUN                Run batch output folders, in pooling priority order
      --output FOLDER    Report folder (default: FIRST_RUN/simulation_statistics)
      --cache-windows N  Window count used only to infer update cohorts (default: 24)
      --hive FOLDER      NEMWEB cache; groups dispatch errors by unit region, dispatch and schedule type
    """

    function main(args)
        runs, options = String[], Dict("cache-windows" => "24")
        i = 1
        while i <= length(args)
            a = args[i]
            if a in ("-h", "--help")
                print(USAGE)
                return 0
            elseif a in ("--output", "--cache-windows", "--hive")
                i < length(args) || (println(stderr, USAGE, "\n$a needs a value"); return 2)
                options[a[3:end]] = args[i + 1]
                i += 2
            elseif startswith(a, "--")
                println(stderr, USAGE, "\nunknown option $a")
                return 2
            else
                push!(runs, a)
                i += 1
            end
        end
        isempty(runs) && (println(stderr, USAGE); return 2)
        windows = tryparse(Int, options["cache-windows"])
        (isnothing(windows) || windows < 1) && (println(stderr, "--cache-windows must be positive"); return 2)
        hive = haskey(options, "hive") ? abspath(expanduser(options["hive"])) : nothing
        isnothing(hive) || isdir(hive) || (println(stderr, "cache directory does not exist: $hive"); return 2)
        result, output = try
            result = analyze(runs; cache_windows = windows, hive)
            output = abspath(get(options, "output", joinpath(first(runs), "simulation_statistics")))
            isdir(output) && realpath(output) in [realpath(r) for r in runs] &&
                throw(ArgumentError("--output must be a report subfolder, not a source run root"))
            save_report(result, output)
            result, output
        catch err
            err isa Union{ArgumentError, SystemError, Base.IOError} || rethrow()
            println(stderr, "simulation_statistics: ", sprint(showerror, err))
            return 2
        end
        println("Report: $(joinpath(output, "report.md"))")
        println("Unique completed days: $(result["unique_completed_days"]); unique written intervals: $(result["unique_written_intervals"]); warnings: $(length(result["warnings"]))")
        return 0
    end

end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(SimulationStatistics.main(ARGS))
end
