# Measures one replicate_range chunk on the local hive cache: phase wall times, peak and current
# RSS, model and store sizes, tie-break rows, FCAS parameter keys and per-step update costs.
# From the repository root:
#
#     julia --project=AustralianElectricityMarketsSimulations/test --threads=1 \
#         AustralianElectricityMarketsSimulations/scripts/measure_replicate_range.jl \
#         [start=2026-01-01T04:05:00] [n_steps=288] [out_dir] [hive=~/.nemdb_cache] \
#         [time_series_in_memory=true] [cache_size_mib=1024]
#
# `out_dir` defaults to /run/media/simba/Store/aem_validation/m8_perf/<yyyymmddTHHMM>; put it on a
# disk, not /tmp (tmpfs). The steps must lie inside one trading day.

using AustralianElectricityMarkets
using AustralianElectricityMarketsSimulations
using DataFrames
using Dates
using HiGHS
using Statistics
import PowerSimulations as PSI
using PowerSystems

const AEM_MEASURE = AustralianElectricityMarketsSimulations
const _MEASURE_OPTIMIZER = PSI.JuMP.optimizer_with_attributes(
    HiGHS.Optimizer, "mip_rel_gap" => 0.0, "mip_abs_gap" => 1.0e-10, "output_flag" => false,
)
const _MEASURE_FCAS_TYPES = (
    AEM_MEASURE.FCASOfferLimitParameter, AEM_MEASURE.FCASBandWidthParameter, AEM_MEASURE.FCASUpperSlopeParameter,
    AEM_MEASURE.FCASLowerSlopeParameter, AEM_MEASURE.FCASRampingLimitParameter, AEM_MEASURE.FCASBandPriceParameter,
)

# Update-cost family of a parameter entry type, in the order the families are tested.
function _measure_family(T)
    T <: AEM_MEASURE.TieBreakScaleParameter && return "tie_break"
    T in _MEASURE_FCAS_TYPES && return "fcas"
    T in (AEM_MEASURE.NEMConstraintRHSParameter, AEM_MEASURE.GenericConstraintSlackCostParameter) && return "generic_constraint"
    (
        T === AEM_MEASURE.LossDemandCoefficientParameter || T <: AEM_MEASURE.MNSPBandWidthParameter ||
            T <: AEM_MEASURE.MNSPMaxAvailParameter || T === AEM_MEASURE.MNSPBandPriceParameter
    ) && return "loss_mnsp"
    T in (AEM_MEASURE.RampUpRateTimeSeriesParameter, AEM_MEASURE.RampDownRateTimeSeriesParameter, AEM_MEASURE.InitialPowerTimeSeriesParameter) &&
        return "dispatch"
    return "psi"
end

# Resident set size of this process in bytes (`VmRSS`, kB in /proc).
function _measure_vmrss_bytes()
    for line in eachline("/proc/self/status")
        startswith(line, "VmRSS:") && return parse(Int, split(line)[2]) * 1024
    end
    return 0
end

# Total bytes of the files under `dir`, 0 when it does not exist.
_measure_dir_bytes(dir) = isdir(dir) ? sum(filesize(joinpath(root, f)) for (root, _, fs) in walkdir(dir) for f in fs; init = 0) : 0

# Seconds in a TimerOutputs node (stored in nanoseconds).
_measure_seconds(node) = PSI.TimerOutputs.time(node) / 1.0e9

# Update the parameters and the objective of a built model as `PSI.update_parameters!` does, timing each key.
function _measure_update_probe(simulation, model)
    c = PSI.get_optimization_container(model)
    state = PSI.get_simulation_state(simulation)
    PSI.cost_function_unsynch(c)
    times = Dict{Any, Float64}()
    for key in keys(PSI.get_parameters(c))
        times[key] = @elapsed PSI.update_parameter_values!(model, key, state)
    end
    t_obj = @elapsed PSI.update_objective_function!(c)
    PSI.set_synchronized_status!(PSI.get_objective_expression(c), true)
    return (; times, update_objective_s = t_obj)
end

# Phases a-c (system, build, update probe) on `steps` in `dir`, for the warm-up run.
function _measure_build(db, steps, dir; time_series_in_memory, optimizer)
    mkpath(dir)
    ts_dir = time_series_in_memory ? nothing : mkpath(joinpath(dir, "ts"))
    sys = replication_system(db, first(steps):Minute(5):(last(steps) + Minute(5)); time_series_in_memory, time_series_directory = ts_dir)
    built = AEM_MEASURE._build_range_simulation(sys, steps; optimizer, folder = mkpath(joinpath(dir, "sim")))
    _measure_update_probe(built.simulation, built.model)
    return nothing
end

"""
    measure_replicate_range(db, steps::StepRange{DateTime}, out_dir; time_series_in_memory = true,
        cache_size_mib = 1024, warmup = true, optimizer = _MEASURE_OPTIMIZER) -> Dict{String, Float64}

Solves the trading-day chunk `steps` in phases, timing each, and writes `metrics.csv`, `phases.csv`,
`steps.csv`, `update_by_family.csv`, `skipped_constraints.csv`, `timer_build.txt` and `timer_run.txt`
to `out_dir`. The `warmup` run compiles the phases on the first two intervals before the measured run.

# Arguments
- `db`: an `AEMDB` connection holding the data for `steps` and the interval after the last.
- `steps`: consecutive 5-minute intervals within one trading day and one Market Price Cap year.
- `out_dir`: the output directory, on disk.
- `time_series_in_memory`: as [`replication_system`](@ref); `false` keeps the time series under `out_dir/ts`.
- `cache_size_mib`: the simulation store's write cache.
- `warmup`: whether to run the build and update phases on two intervals first.
- `optimizer`: the JuMP optimizer.

# Returns
The metrics as a `Dict` from name to value.
"""
function measure_replicate_range(
        db, steps::StepRange{DateTime}, out_dir::AbstractString;
        time_series_in_memory::Bool = true, cache_size_mib::Int = 1024, warmup::Bool = true,
        optimizer = _MEASURE_OPTIMIZER,
    )
    length(AEM_MEASURE._range_chunks(steps, :trading_day)) == 1 ||
        throw(ArgumentError("steps cross a trading day or 1 July"))
    mkpath(out_dir)
    if warmup
        _measure_build(
            db, first(steps):Minute(5):(first(steps) + Minute(5)), joinpath(out_dir, "warmup");
            time_series_in_memory, optimizer,
        )
        GC.gc()
    end

    phases = NamedTuple[]
    probe(name, wall_s) = push!(
        phases, (; phase = name, wall_s, maxrss_bytes = Sys.maxrss(), vmrss_bytes = _measure_vmrss_bytes(), gc_live_bytes = Base.gc_live_bytes()),
    )
    probe("start", 0.0)

    ts_dir = time_series_in_memory ? nothing : mkpath(joinpath(out_dir, "ts"))
    sim_dir = joinpath(out_dir, "sim")
    mkpath(sim_dir)
    local sys, built
    system_s = @elapsed sys = replication_system(
        db, first(steps):Minute(5):(last(steps) + Minute(5)); time_series_in_memory, time_series_directory = ts_dir,
    )
    probe("system", system_s)
    simulation_build_s = @elapsed built = AEM_MEASURE._build_range_simulation(sys, steps; optimizer, folder = sim_dir)
    (; simulation, model, skipped_constraints) = built
    probe("simulation_build", simulation_build_s)
    build_timer = PSI.BUILD_PROBLEMS_TIMER["Build Simulation"]
    write(joinpath(out_dir, "timer_build.txt"), sprint(show, PSI.BUILD_PROBLEMS_TIMER))
    build_phases = Dict(
        "build_decision_problems_s" => _measure_seconds(build_timer["Build Decision Problems"]),
        "initialize_simulation_state_s" => _measure_seconds(build_timer["Initialize Simulation State"]),
        "initialize_problem_storage_s" => _measure_seconds(build_timer["Initialize Problem Storage"]),
    )

    _measure_update_probe(simulation, model)
    probe_result = _measure_update_probe(simulation, model)
    update_probe_s = sum(values(probe_result.times)) + probe_result.update_objective_s
    probe("update_probe", update_probe_s)

    container = PSI.get_optimization_container(model)
    family_keys = Dict{String, Int}()
    family_seconds = Dict{String, Float64}()
    for (key, t) in probe_result.times
        family = _measure_family(PSI.IS.Optimization.get_entry_type(key))
        family_keys[family] = get(family_keys, family, 0) + 1
        family_seconds[family] = get(family_seconds, family, 0.0) + t
    end

    execute_s = @elapsed results = AEM_MEASURE._execute_range_simulation(simulation; cache_size_mib)
    probe("execute", execute_s)
    write(joinpath(out_dir, "timer_run.txt"), sprint(show, PSI.RUN_SIMULATION_TIMER))

    compare_s = @elapsed begin
        frames = AEM_MEASURE._solved_frames(results, sys; losses = true)
        AEM_MEASURE._check_prices_finite(frames.balance_duals)
        comparison = AEM_MEASURE._compare_range_to_published(db, sys, frames, steps, 0)
        violations = AEM_MEASURE._constraint_violations(results, sys)
    end
    probe("compare", compare_s)

    # Counts and per-step costs.
    jm = PSI.get_jump_model(container)
    params = PSI.get_parameters(container)
    stats = PSI.read_optimizer_stats(results)
    n_steps = length(steps)
    metrics = Dict{String, Float64}()
    metrics["n_steps"] = n_steps
    metrics["jump_variables"] = PSI.JuMP.num_variables(jm)
    metrics["jump_constraints"] = PSI.JuMP.num_constraints(jm; count_variable_in_set_constraints = false)
    metrics["parameter_keys"] = length(params)
    metrics["variable_keys"] = length(PSI.get_variables(container))
    metrics["dual_keys"] = length(PSI.get_duals(container))
    metrics["expression_keys"] = length(PSI.get_expressions(container))
    metrics["stored_parameter_keys"] = count(PSI.should_write_resulting_value, keys(params))
    metrics["stored_variable_keys"] = count(PSI.should_write_resulting_value, keys(PSI.get_variables(container)))
    metrics["stored_expression_keys"] = count(PSI.should_write_resulting_value, keys(PSI.get_expressions(container)))
    fcas_keys = [k for k in keys(params) if PSI.IS.Optimization.get_entry_type(k) in _MEASURE_FCAS_TYPES]
    metrics["fcas_parameter_keys"] = length(fcas_keys)
    metrics["fcas_parameter_cells"] = sum(length(PSI.get_multiplier_array(params[k])) for k in fcas_keys; init = 0)
    metrics["generic_constraints_modeled"] = count(
        k -> PSI.IS.Optimization.get_entry_type(k) === AEM_MEASURE.NEMConstraintLimit, keys(PSI.get_duals(container)),
    )
    for reason in unique(skipped_constraints.reason)
        metrics["skipped_$(reason)"] = count(==(reason), skipped_constraints.reason)
    end
    tie_total = 0
    tie = AEM_MEASURE._tie_break_offers(sys)
    for ((decremental, region), (; stamps, offers)) in pairs(tie)
        n = length(AEM_MEASURE._tie_break_pairs(offers, findfirst(==(first(steps)), stamps)))
        metrics["tie_rows_$(decremental ? "LOAD" : "GEN")_$(region)"] = n
        tie_total += n
    end
    metrics["tie_rows_total"] = tie_total
    metrics["tie_break_parameter_keys"] = count(
        k -> PSI.IS.Optimization.get_entry_type(k) === AEM_MEASURE.TieBreakScaleParameter, keys(params),
    )

    R = PSI.RUN_SIMULATION_TIMER["Execute Simulation"]["Execute dispatch"]
    per_update = PSI.TimerOutputs.ncalls(R["Update dispatch"]["Parameter Updates"]) == 0 ? 0.0 :
        _measure_seconds(R["Update dispatch"]["Parameter Updates"]) / PSI.TimerOutputs.ncalls(R["Update dispatch"]["Parameter Updates"])
    per_solve_section = _measure_seconds(R["Solve dispatch"]) / PSI.TimerOutputs.ncalls(R["Solve dispatch"])
    per_update_state = _measure_seconds(R["Update State"]) / PSI.TimerOutputs.ncalls(R["Update State"])
    solve_sum = sum(stats.timed_solve_time)
    dual_sum = sum(stats.timed_calculate_dual_variables)
    metrics["per_step_update_s"] = per_update
    metrics["per_step_update_state_s"] = per_update_state
    metrics["per_step_solve_section_s"] = per_solve_section
    metrics["per_step_optimize_s"] = mean(stats.timed_solve_time)
    metrics["max_step_optimize_s"] = maximum(stats.timed_solve_time)
    metrics["per_step_dual_pass_s"] = mean(stats.timed_calculate_dual_variables)
    metrics["max_step_dual_pass_s"] = maximum(stats.timed_calculate_dual_variables)
    metrics["per_step_solver_s"] = mean(stats.solver_solve_time)
    metrics["per_step_write_and_other_s"] = per_solve_section - metrics["per_step_optimize_s"] - metrics["per_step_dual_pass_s"]
    metrics["per_step_non_solve_s"] = per_update + metrics["per_step_write_and_other_s"] + per_update_state
    metrics["amortized_non_solve_s"] =
        (system_s + simulation_build_s + execute_s + compare_s - solve_sum - dual_sum) / n_steps
    merge!(metrics, build_phases)
    metrics["system_s"] = system_s
    metrics["simulation_build_s"] = simulation_build_s
    metrics["execute_s"] = execute_s
    metrics["compare_s"] = compare_s
    metrics["update_probe_s"] = update_probe_s
    metrics["update_objective_s"] = probe_result.update_objective_s
    for family in ("fcas", "generic_constraint", "tie_break", "loss_mnsp", "dispatch", "psi")
        metrics["update_$(family)_s"] = get(family_seconds, family, 0.0)
        metrics["update_$(family)_keys"] = get(family_keys, family, 0)
    end

    # Memory and store.
    metrics["peak_rss_bytes"] = Sys.maxrss()
    metrics["peak_rss_gib"] = Sys.maxrss() / 2^30
    for p in phases
        metrics["vmrss_after_$(p.phase)"] = p.vmrss_bytes
    end
    store_file = joinpath(PSI.get_store_dir(simulation), PSI.HDF_FILENAME)
    metrics["store_bytes"] = isfile(store_file) ? filesize(store_file) : 0
    metrics["sim_folder_bytes"] = _measure_dir_bytes(sim_dir)
    metrics["ts_bytes"] = _measure_dir_bytes(joinpath(out_dir, "ts"))

    _write_measure_files(out_dir, metrics, phases, steps, stats, probe_result.times, family_keys, family_seconds, skipped_constraints)
    return metrics
end

# Writes the CSV files of `measure_replicate_range` (no CSV package: values carry no commas).
function _write_measure_files(out_dir, metrics, phases, steps, stats, times, family_keys, family_seconds, skipped)
    unit(name) = endswith(name, "_bytes") ? "bytes" : endswith(name, "_gib") ? "GiB" : endswith(name, "_s") ? "s" : "count"
    open(joinpath(out_dir, "metrics.csv"), "w") do io
        println(io, "metric,value,unit")
        for name in sort!(collect(keys(metrics)))
            println(io, join((name, repr(metrics[name]), unit(name)), ","))
        end
    end
    open(joinpath(out_dir, "phases.csv"), "w") do io
        println(io, "phase,wall_s,maxrss_bytes,vmrss_bytes,gc_live_bytes")
        for p in phases
            println(io, join((p.phase, repr(p.wall_s), p.maxrss_bytes, p.vmrss_bytes, p.gc_live_bytes), ","))
        end
    end
    open(joinpath(out_dir, "steps.csv"), "w") do io
        println(io, "SETTLEMENTDATE,objective_value,solver_solve_time,timed_solve_time,timed_calculate_dual_variables,termination_status")
        for (i, t) in enumerate(steps)
            row = (
                string(t), stats.objective_value[i], stats.solver_solve_time[i], stats.timed_solve_time[i],
                stats.timed_calculate_dual_variables[i], stats.termination_status[i],
            )
            println(io, join(map(v -> v isa AbstractFloat ? repr(v) : string(v), row), ","))
        end
    end
    open(joinpath(out_dir, "update_by_family.csv"), "w") do io
        println(io, "family,keys,seconds")
        for family in sort!(collect(keys(family_keys)))
            println(io, join((family, family_keys[family], repr(family_seconds[family])), ","))
        end
    end
    open(joinpath(out_dir, "skipped_constraints.csv"), "w") do io
        println(io, "constraint,stage,reason,n_missing")
        for r in eachrow(skipped)
            println(io, join((r.constraint, r.stage, r.reason, r.n_missing), ","))
        end
    end
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    start = DateTime(length(ARGS) >= 1 ? ARGS[1] : "2026-01-01T04:05:00")
    n_steps = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 288
    out_dir = length(ARGS) >= 3 ? ARGS[3] :
        joinpath("/run/media/simba/Store/aem_validation/m8_perf", Dates.format(now(), "yyyymmddTHHMM"))
    hive = length(ARGS) >= 4 ? ARGS[4] : joinpath(homedir(), ".nemdb_cache")
    in_memory = length(ARGS) >= 5 ? parse(Bool, ARGS[5]) : true
    cache_mib = length(ARGS) >= 6 ? parse(Int, ARGS[6]) : 1024
    db = aem_connect(HiveConfiguration(hive_location = hive))
    steps = start:Minute(5):(start + Minute(5) * (n_steps - 1))
    metrics = measure_replicate_range(db, steps, out_dir; time_series_in_memory = in_memory, cache_size_mib = cache_mib)
    for name in (
            "peak_rss_gib", "system_s", "simulation_build_s", "initialize_problem_storage_s", "execute_s", "compare_s",
            "per_step_update_s", "per_step_update_state_s", "per_step_optimize_s", "per_step_dual_pass_s",
            "per_step_write_and_other_s", "amortized_non_solve_s", "store_bytes", "tie_rows_total",
            "fcas_parameter_keys", "update_fcas_s", "update_objective_s", "generic_constraints_modeled",
        )
        println("MEASURE $name=$(metrics[name])")
    end
    println("MEASURE DONE $out_dir")
end
