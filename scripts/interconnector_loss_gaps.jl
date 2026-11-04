# Checks the solved interconnector losses of a saved replay against the loss curve at the solved
# flow, and reports the weighted marginal price of loss. From the repository root:
#
#     julia --project=AustralianElectricityMarketsSimulations/test scripts/interconnector_loss_gaps.jl \
#         --results <replay folder> --start 2025-01-01T00:05:00 --stop 2025-01-01T00:10:00 \
#         [--hive <dir>] [--output <csv>] [--tolerance <MW>]
#
# `--results` is the `output_dir` of `replicate_range`, holding `chunk_<k>` folders. The system is
# rebuilt over the same range, so the results must come from a replay whose template models
# `PSY.AreaInterchange` (the default `template_nemde()` does).

module InterconnectorLossGaps

    using AustralianElectricityMarkets:
        HiveConfiguration, DISPATCH_INTERVAL, NEMDEConfiguration, aem_connect, nem_system
    using AustralianElectricityMarketsSimulations: _prepare_replay_forecasts!, read_interconnector_loss_gaps
    using DataFrames
    using Dates
    using Printf
    import PowerSimulations as PSI
    import PowerSystems as PSY

    # Names written by `ReplayWorkflow.replicate_range`.
    const SIMULATION_NAME = "replay_workflow"
    const PROBLEM_NAME = "dispatch"

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

    Rebuilds the NEMDE system over the replayed range and writes the `read_interconnector_loss_gaps` table of
    every `chunk_<k>` folder of `--results` to `--output` (CSV) when given. Warns when any `|gap_mw|` exceeds
    `--tolerance`, and prints the maximum absolute gap and the number of intervals with a negative weighted
    loss price per interconnector.

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
        _prepare_replay_forecasts!(sys)

        tables = map(sort(chunk_folders; by = chunk_index)) do folder
            results = PSI.get_decision_problem_results(PSI.SimulationResults(folder, SIMULATION_NAME), PROBLEM_NAME)
            return read_interconnector_loss_gaps(results, sys)
        end
        table = reduce(vcat, tables)
        isempty(table) && throw(ArgumentError("no interconnector loss rows in $results_dir"))

        flagged = count(g -> abs(g) > tolerance, table.gap_mw)
        flagged == 0 ||
            @warn "main: $flagged (interconnector, DateTime) row(s) have a solved loss off the loss curve at the solved flow" tolerance
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
