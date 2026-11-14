# Captures one replay of the NEM dispatch as a baseline: prepares the system, builds and executes the
# simulation over a range of intervals, and writes the snapshot, the metrics, the skipped constraints,
# the interval comparison and a README into the output folder.
#
# Usage: julia --project=AustralianElectricityMarketsSimulations/test capture.jl \
#     --hive <mock|PATH> --start <ISO DateTime> --intervals <N> --out <DIR> [--warm]

using AustralianElectricityMarkets
using AustralianElectricityMarketsSimulations
using DataFrames
using Dates
using DuckDB
using Logging
using Serialization
using Statistics
using TOML
import PowerSimulations as PSI
import PowerSystems as PSY

const AEM = AustralianElectricityMarkets
const AEMS = AustralianElectricityMarketsSimulations

const REPO_ROOT = abspath(joinpath(@__DIR__, "..", "..", ".."))
const MOCK_FIXTURE = joinpath(REPO_ROOT, "test", "fixtures", "mock_data.jl")
const STEP = Dates.Minute(5)
const DECISION_NAME = "dispatch"

include(joinpath(@__DIR__, "snapshot.jl"))
include(MOCK_FIXTURE)

# Parses the command line into a NamedTuple of options.
function _parse_capture_args(args::Vector{String})
    options = Dict{String, String}()
    warm = false
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--warm"
            warm = true; i += 1
        elseif startswith(arg, "--") && i < length(args)
            options[arg[3:end]] = args[i + 1]; i += 2
        else
            error("unexpected argument $arg")
        end
    end
    for key in ("hive", "start", "intervals", "out")
        haskey(options, key) || error("missing --$key")
    end
    return (;
        hive = options["hive"], start = DateTime(options["start"]),
        intervals = parse(Int, options["intervals"]), out = abspath(options["out"]), warm,
    )
end

# The database for `hive`: a fresh mock hive for `mock`, otherwise the hive at that path.
function _connect(hive::AbstractString)
    location = if hive == "mock"
        dir = mktempdir()
        create_mock_data(dir; complete_inputs = true)
        write_mock_interconnector_results(dir)
        dir
    else
        abspath(hive)
    end
    return aem_connect(HiveConfiguration(hive_location = location, filesystem = "file"))
end

# Builds the system, prepares it and builds the simulation of `steps` in `folder`. Returns the parts
# the caller needs with the phase timings in seconds.
function _build(db, steps::StepRange{DateTime}, template, optimizer, folder::AbstractString)
    horizon = first(steps):STEP:(last(steps) + 2STEP)
    mkpath(folder)
    t = time()
    sys = nem_system(
        db, NEMDEConfiguration(); date_range = horizon, intervention = 0, interval_flow_limits = false,
        time_series_in_memory = true,
    )
    system_build_s = time() - t
    t = time()
    skipped = isdefined(AEMS, :prepare_replay!) ? AEMS.prepare_replay!(sys, template, steps) :
        AEMS.replay_skipped_constraints(sys, template)
    prepare_s = time() - t
    t = time()
    model = PSI.DecisionModel(
        AEMS.NEMDispatchProblem, template, sys; optimizer, initial_time = first(steps), name = DECISION_NAME,
    )
    models = PSI.SimulationModels(; decision_models = [model])
    sequence = PSI.SimulationSequence(; models, ini_cond_chronology = PSI.InterProblemChronology())
    simulation = PSI.Simulation(;
        name = "capture", steps = length(steps), models, sequence, simulation_folder = folder,
        initial_time = first(steps),
    )
    status = PSI.build!(simulation; store_systems_in_results = false)
    model_build_s = time() - t
    status == PSI.SimulationBuildStatus.BUILT || error("range from $(first(steps)) failed to build ($status)")
    return (; sys, model, simulation, skipped, system_build_s, prepare_s, model_build_s)
end

# Writes `table` as CSV with a header row; missing cells are empty.
function _write_csv(path::AbstractString, table::DataFrame)
    cell(v) = ismissing(v) ? "" :
        (v isa AbstractString && occursin(r"[,\"\n]", v)) ? "\"" * replace(v, "\"" => "\"\"") * "\"" : string(v)
    open(path, "w") do io
        println(io, join(names(table), ","))
        for row in eachrow(table)
            println(io, join((cell(v) for v in row), ","))
        end
    end
    return path
end

# The output of `git args...` in the repository.
_git(args::String...) = readchomp(Cmd(Cmd(["git", args...]); dir = REPO_ROOT))

# The commit, branch and cleanliness of the repository this script runs from.
function _git_state()
    commit = _git("rev-parse", "HEAD")
    branch = _git("rev-parse", "--abbrev-ref", "HEAD")
    dirty = !isempty(_git("status", "--porcelain"))
    return (; commit, branch, dirty)
end

"""
    capture(; hive, start, intervals, out, warm) -> Nothing

Runs one replay of `intervals` five-minute steps from `start` and writes the capture folder `out`.
See the header of this file for the options.
"""
function capture(; hive::AbstractString, start::DateTime, intervals::Integer, out::AbstractString, warm::Bool)
    intervals >= 1 || error("--intervals must be at least 1")
    steps = start:STEP:(start + STEP * (intervals - 1))
    mkpath(out)
    git = _git_state()
    open(joinpath(out, "run.log"), "w") do log
        say(msg) = (println(msg); println(log, msg); flush(log))
        with_logger(ConsoleLogger(log, Logging.Info)) do
            say("capture: $hive $start x $intervals -> $out")
            db = _connect(hive)
            template = AEMS.template_nemde()
            optimizer = AEMS.nemde_optimizer()
            built = _build(db, steps, template, optimizer, joinpath(out, "sim"))
            say("built: system $(round(built.system_build_s; digits = 2)) s, prepare $(round(built.prepare_s; digits = 2)) s, model $(round(built.model_build_s; digits = 2)) s")
            key_types = key_type_count(built.model)

            t = time()
            status = PSI.execute!(built.simulation)
            execute_s = time() - t
            status == PSI.RunStatus.SUCCESSFULLY_FINALIZED || error("range from $start failed to execute ($status)")
            results = PSI.get_decision_problem_results(PSI.SimulationResults(built.simulation), DECISION_NAME)
            say("executed in $(round(execute_s; digits = 2)) s")

            snapshot = replay_snapshot(results, built.sys)
            serialize(joinpath(out, "snapshot.jls"), snapshot)
            stats = PSI.read_optimizer_stats(results)
            timed = collect(Float64, stats.timed_solve_time)
            comparison = compare_intervals(read_published_interval(db, steps), read_solved_interval(results, built.sys))
            _write_csv(joinpath(out, "comparison_summary.csv"), comparison_summary(comparison))
            _write_csv(joinpath(out, "skipped_constraints.csv"), DataFrame(built.skipped))

            metrics = Dict{String, Any}(
                "commit" => git.commit,
                "n_intervals" => length(steps),
                "key_type_count" => key_types,
                "system_build_s" => built.system_build_s,
                "prepare_s" => built.prepare_s,
                "model_build_s" => built.model_build_s,
                "execute_s" => execute_s,
                "execute_s_per_interval" => execute_s / length(steps),
                "timed_solve_p50" => quantile(timed, 0.5),
                "timed_solve_p95" => quantile(timed, 0.95),
                "timed_solve_max" => maximum(timed),
            )
            if warm
                # The second build in this process, in its own folder, for the warm timings.
                w = _build(db, steps, AEMS.template_nemde(), optimizer, joinpath(out, "sim_warm"))
                metrics["warm_system_build_s"] = w.system_build_s
                metrics["warm_prepare_s"] = w.prepare_s
                metrics["warm_model_build_s"] = w.model_build_s
                say("warm build: system $(round(w.system_build_s; digits = 2)) s, prepare $(round(w.prepare_s; digits = 2)) s, model $(round(w.model_build_s; digits = 2)) s")
            end
            open(io -> TOML.print(io, metrics), joinpath(out, "metrics.toml"), "w")

            solver = join(("$k = $v" for (k, v) in AEMS.NEMDE_HIGHS_OPTIONS), "; ")
            outcome = "solved and compared $(length(steps)) intervals; snapshot has $(length(snapshot)) tables"
            open(joinpath(out, "README.md"), "w") do io
                println(io, "# Replay capture: $hive from $start, $(length(steps)) intervals\n")
                println(io, "Purpose: baseline for the replay comparison gate of the PSI split refactor.")
                println(io, "Command: `capture.jl $(join(ARGS, " "))`")
                println(io, "Branch: $(git.branch)")
                println(io, "Commit: $(git.commit)")
                println(io, "Tree: $(git.dirty ? "dirty" : "clean")")
                println(io, "Range: $(first(steps)) to $(last(steps)) ($(length(steps)) intervals)")
                println(io, "Solver options: $solver")
                println(io, "Outcome: $outcome.")
            end
            say("outcome: $outcome")
        end
    end
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    capture(; _parse_capture_args(collect(String, ARGS))...)
end
