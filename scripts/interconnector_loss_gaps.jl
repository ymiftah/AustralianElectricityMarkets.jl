# Checks the solved interconnector losses of a saved replay against the loss curve at the solved
# flow, and reports the weighted marginal price of loss. From the repository root:
#
#     julia --project=AustralianElectricityMarketsSimulations/test scripts/interconnector_loss_gaps.jl \
#         --results <replay folder> --start 2025-01-01T00:05:00 --stop 2025-01-01T00:10:00 \
#         [--hive <dir>] [--output <csv>] [--tolerance <MW>]
#
# `--results` is the `output_dir` of `replicate_range`, holding `chunk_<k>` folders. The system is
# rebuilt over the same range, so the results must come from a replay with `:losses` in its parts.

module InterconnectorLossGaps

    using AustralianElectricityMarkets:
        HiveConfiguration, InterconnectorLossModel, DISPATCH_INTERVAL, NEM_SERIES, NEMDEConfiguration,
        aem_connect, loss_curve_vertex_values, nem_system, prepare_replay_forecasts!
    using AustralianElectricityMarketsSimulations: InterconnectorLossVariable
    using DataFrames
    using Dates
    using Printf
    import PowerSimulations as PSI
    import PowerSystems as PSY

    # Names written by `ReplayWorkflow.replicate_range`.
    const SIMULATION_NAME = "replay_workflow"
    const PROBLEM_NAME = "dispatch"
    const COLUMNS = ("interconnector", "DateTime", "flow_mw", "solved_loss_mw", "curve_loss_mw", "gap_mw", "weighted_loss_price")

    # Replay results hold each step's final value (realized); a live model's results hold its whole horizon.
    _read_variable(results::PSI.SimulationProblemResults, key::AbstractString) = PSI.read_realized_variable(results, key)
    _read_variable(results, key::AbstractString) = PSI.read_variable(results, key)
    _read_dual(results::PSI.SimulationProblemResults, key::AbstractString) = PSI.read_realized_dual(results, key)
    _read_dual(results, key::AbstractString) = PSI.read_dual(results, key)

    """
        _loss_rows(results, sys) -> DataFrame

    One row per `(interconnector, DateTime)` with a solved flow: the solved loss, the loss curve at the
    solved flow and their difference, all in MW.

    # Arguments

      - `results`: PSI results of a solved model using `NEMInterconnectorLoss`.
      - `sys::PSY.System`: the system the model was built from.

    # Returns

      - `DataFrame`: columns `interconnector`, `DateTime`, `flow_mw`, `solved_loss_mw`, `curve_loss_mw`, `gap_mw`.
    """
    function _loss_rows(results, sys::PSY.System)
        flow_df = _read_variable(results, "FlowActivePowerVariable__AreaInterchange")
        loss_df = _read_variable(results, "InterconnectorLossVariable__AreaInterchange")
        stamps = sort(unique(flow_df.DateTime))
        base_power = PSY.get_base_power(sys)
        flows = Dict((r.name, r.DateTime) => r.value for r in eachrow(flow_df))
        losses = Dict((r.name, r.DateTime) => r.value for r in eachrow(loss_df))
        rows = DataFrame(
            interconnector = String[], DateTime = DateTime[], flow_mw = Float64[],
            solved_loss_mw = Float64[], curve_loss_mw = Float64[], gap_mw = Float64[],
        )
        for d in PSY.get_components(PSY.AreaInterchange, sys)
            name = PSY.get_name(d)
            models = PSY.get_supplemental_attributes(InterconnectorLossModel, d)
            length(models) == 1 || continue
            model = only(models)
            at_zero = loss_curve_vertex_values(model, Dict{String, Float64}())
            coefficients = PSY.get_time_series_values(
                PSY.SingleTimeSeries, d, NEM_SERIES.loss_demand_coefficient; start_time = first(stamps), len = length(stamps),
            )
            for (t, stamp) in enumerate(stamps)
                haskey(flows, (name, stamp)) || continue
                flow_mw = flows[(name, stamp)]
                flow_pu = flow_mw / base_power
                # The loss curve is linear between breakpoints, so interpolate its vertex values at the flow.
                vertex_losses = at_zero .+ coefficients[t] .* model.breakpoints
                segment = clamp(searchsortedlast(model.breakpoints, flow_pu), 1, length(model.breakpoints) - 1)
                lo, hi = model.breakpoints[segment:(segment + 1)]
                loss_lo, loss_hi = vertex_losses[segment], vertex_losses[segment + 1]
                curve_pu = loss_lo + (flow_pu - lo) * (loss_hi - loss_lo) / (hi - lo)
                curve_mw = curve_pu * base_power
                push!(rows, (name, stamp, flow_mw, losses[(name, stamp)], curve_mw, losses[(name, stamp)] - curve_mw))
            end
        end
        return rows
    end

    """
        interconnector_loss_gaps(results, sys) -> Dict{Tuple{String, Int}, Float64}

    Solved interconnector loss minus the loss curve at the solved flow, in MW, per `(interconnector name, t)`.
    `t` indexes the sorted result timestamps. Zero wherever the segment allocation reproduces the loss
    curve's chord value at that flow; positive where the solver dissipated more than the curve at that flow.

    # Arguments

      - `results`: PSI results of one solved model using `NEMInterconnectorLoss`.
      - `sys::PSY.System`: the system the model was built from.

    # Returns

      - `Dict{Tuple{String, Int}, Float64}`: the gap in MW keyed by `(interconnector, t)`.
    """
    function interconnector_loss_gaps(results, sys::PSY.System)
        rows = _loss_rows(results, sys)
        stamp_index = Dict(stamp => t for (t, stamp) in enumerate(sort(unique(rows.DateTime))))
        gaps = Dict{Tuple{String, Int}, Float64}()
        for r in eachrow(rows)
            gaps[(r.interconnector, stamp_index[r.DateTime])] = r.gap_mw
        end
        return gaps
    end

    """
        check_interconnector_loss_segments(results, sys; tolerance = 1.0e-3) -> Dict{Tuple{String, Int}, Float64}

    Calls [`interconnector_loss_gaps`](@ref) and `@warn`s once, naming every `(interconnector, t)` whose
    absolute gap exceeds `tolerance` MW.

    # Arguments

      - `results`: PSI results of one solved model using `NEMInterconnectorLoss`.
      - `sys::PSY.System`: the system the model was built from.
      - `tolerance::Float64`: the largest absolute gap in MW that is not flagged.

    # Returns

      - `Dict{Tuple{String, Int}, Float64}`: the output of [`interconnector_loss_gaps`](@ref).
    """
    function check_interconnector_loss_segments(results, sys::PSY.System; tolerance::Float64 = 1.0e-3)
        gaps = interconnector_loss_gaps(results, sys)
        flagged = [(k, v) for (k, v) in gaps if abs(v) > tolerance]
        isempty(flagged) ||
            @warn "check_interconnector_loss_segments: $(length(flagged)) (interconnector, t) pair(s) have a solved loss that does not match the loss curve at the solved flow" flagged
        return gaps
    end

    """
        loss_gap_table(results, sys; tolerance = 1.0e-3) -> DataFrame

    One row per interconnector and interval with a solved flow, with the loss gap in MW and the weighted
    marginal price of loss `share * price_from + (1 - share) * price_to` in \$/MWh, from the
    `CopperPlateBalanceConstraint__Area` duals. Warns once when any `|gap_mw|` exceeds `tolerance`.

    # Arguments

      - `results`: PSI results of one solved model using `NEMInterconnectorLoss`.
      - `sys::PSY.System`: the system the model was built from.
      - `tolerance::Float64`: the largest absolute gap in MW that is not flagged.

    # Returns

      - `DataFrame`: columns `interconnector`, `DateTime`, `flow_mw`, `solved_loss_mw`, `curve_loss_mw`,
        `gap_mw` and `weighted_loss_price`.
    """
    function loss_gap_table(results, sys::PSY.System; tolerance::Float64 = 1.0e-3)
        rows = _loss_rows(results, sys)
        price_df = _read_dual(results, "CopperPlateBalanceConstraint__Area")
        price = Dict((r.name, r.DateTime) => r.value for r in eachrow(price_df))
        models = Dict{String, InterconnectorLossModel}()
        for d in PSY.get_components(PSY.AreaInterchange, sys)
            found = PSY.get_supplemental_attributes(InterconnectorLossModel, d)
            length(found) == 1 && (models[PSY.get_name(d)] = only(found))
        end
        weighted = Float64[]
        for r in eachrow(rows)
            model = models[r.interconnector]
            pf = get(price, (model.from_region, r.DateTime), NaN)
            pt = get(price, (model.to_region, r.DateTime), NaN)
            push!(weighted, model.from_region_loss_share * pf + (1 - model.from_region_loss_share) * pt)
        end
        rows[!, :weighted_loss_price] = weighted
        flagged = count(g -> abs(g) > tolerance, rows.gap_mw)
        flagged == 0 ||
            @warn "loss_gap_table: $flagged (interconnector, DateTime) row(s) have a solved loss off the loss curve at the solved flow" tolerance
        return rows
    end

    const _OPTIONS = ("results", "start", "stop", "hive", "output", "tolerance")

    # Parses `--name value` pairs into a `Dict` keyed by name without dashes.
    function _parse_args(args)
        options = Dict{String, String}()
        i = 1
        while i <= length(args)
            flag = args[i]
            startswith(flag, "--") && flag[3:end] in _OPTIONS || throw(ArgumentError("unknown argument $flag"))
            i < length(args) || throw(ArgumentError("$flag needs a value"))
            options[flag[3:end]] = args[i + 1]
            i += 2
        end
        for required in ("results", "start", "stop")
            haskey(options, required) || throw(ArgumentError("--$required is required"))
        end
        return options
    end

    function _write_csv(path::AbstractString, table::DataFrame)
        open(path, "w") do io
            println(io, join(names(table), ","))
            for row in eachrow(table)
                println(io, join((string(v) for v in row), ","))
            end
        end
        return path
    end

    """
        main(args = ARGS) -> DataFrame

    Rebuilds the NEMDE system over the replayed range and writes the [`loss_gap_table`](@ref) of every
    `chunk_<k>` folder of `--results` to `--output` (CSV) when given. Prints the maximum absolute gap and the
    number of intervals with a negative weighted loss price per interconnector.

    # Arguments

      - `args`: `--results <folder> --start <DateTime> --stop <DateTime>` with optional `--hive <dir>`
        (default `~/.nemdb_cache`), `--output <csv>` and `--tolerance <MW>` (default `1e-3`).

    # Returns

      - `DataFrame`: the rows of the table of every chunk.
    """
    function main(args = ARGS)
        options = _parse_args(args)
        results_dir = options["results"]
        isdir(results_dir) || throw(ArgumentError("--results $results_dir is not a folder"))
        start = DateTime(options["start"])
        stop = DateTime(options["stop"])
        tolerance = parse(Float64, get(options, "tolerance", "1e-3"))
        hive = get(options, "hive", joinpath(homedir(), ".nemdb_cache"))

        chunk_folders = filter(p -> isdir(p) && startswith(basename(p), "chunk_"), readdir(results_dir; join = true))
        isempty(chunk_folders) && throw(ArgumentError("no chunk_<k> folders under $results_dir"))
        chunk_index(p) = parse(Int, last(split(basename(p), '_')))

        # The same system and range that `replicate_range` built for these intervals.
        db = aem_connect(HiveConfiguration(hive_location = hive))
        sys = nem_system(db, NEMDEConfiguration(); date_range = start:DISPATCH_INTERVAL:(stop + 2DISPATCH_INTERVAL))
        prepare_replay_forecasts!(sys)

        tables = map(sort(chunk_folders; by = chunk_index)) do folder
            results = PSI.get_decision_problem_results(PSI.SimulationResults(folder, SIMULATION_NAME), PROBLEM_NAME)
            return loss_gap_table(results, sys; tolerance)
        end
        table = reduce(vcat, tables)
        isempty(table) && throw(ArgumentError("no interconnector loss rows in $results_dir"))

        haskey(options, "output") && _write_csv(options["output"], table)
        println("Interconnector loss gaps, $start to $stop ($(nrow(table)) rows)")
        for name in sort(unique(table.interconnector))
            rows = table[table.interconnector .== name, :]
            @printf(
                "%-12s max |gap| %.6g MW   negative weighted loss price intervals %d\n",
                name, maximum(abs, rows.gap_mw), count(<(0), rows.weighted_loss_price),
            )
        end
        return table
    end

end

if abspath(PROGRAM_FILE) == @__FILE__
    InterconnectorLossGaps.main(ARGS)
end
