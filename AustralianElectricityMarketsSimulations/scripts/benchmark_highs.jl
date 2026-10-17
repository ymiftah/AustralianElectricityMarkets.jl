# Compare HiGHS settings on identical cached replay windows, one configuration per process.
# From the repository root:
# julia --project=AustralianElectricityMarketsSimulations/test --threads=1 \
#     AustralianElectricityMarketsSimulations/scripts/benchmark_highs.jl \
#     <out_dir> [threads=1] [parallel=off] [hive=~/.nemdb_cache] [n_steps=6] [analysis_level=384] [heuristic_effort=0.05] [time_limit=Inf] [rel_gap=0.0] [abs_gap=1e-10]
# Use fresh output directories and processes for each configuration. No data are populated.

include(joinpath(@__DIR__, "measure_replicate_range.jl"))
include(joinpath(@__DIR__, "range_vs_nemde.jl"))

# Each backend gets a separate log, including those created by the pricing pass.
function _benchmark_optimizer(dir, threads, parallel, analysis_level, heuristic_effort, time_limit; rel_gap = 0.0, abs_gap = 1.0e-10)
    mkpath(dir)
    count = Ref(0)
    function factory()
        count[] += 1
        optimizer = HiGHS.Optimizer()
        for (name, value) in (
                "threads" => threads, "parallel" => parallel,
                "mip_rel_gap" => rel_gap, "mip_abs_gap" => abs_gap,
                "mip_heuristic_effort" => heuristic_effort, "time_limit" => time_limit,
                "highs_analysis_level" => analysis_level,
                "output_flag" => true, "log_to_console" => false,
                "log_file" => joinpath(dir, "highs_$(lpad(count[], 4, '0')).log"),
            )
            PSI.MOI.set(optimizer, PSI.MOI.RawOptimizerAttribute(name), value)
        end
        return optimizer
    end
    return PSI.JuMP.optimizer_with_attributes(factory)
end

# Read dispatch and prices from the measured simulation for validation.
function _benchmark_comparison(db, steps, out_dir)
    sys = replication_system(db, first(steps):Minute(5):(last(steps) + Minute(5)))
    results = PSI.get_decision_problem_results(PSI.SimulationResults(joinpath(out_dir, "sim")), "dispatch")
    stats = PSI.read_optimizer_stats(results)
    all(==(Int(PSI.MOI.OPTIMAL)), stats.termination_status) || error("Benchmark dispatch did not reach optimal status at the configured MIP gaps; results are not accepted.")
    frames = AEM_COMPARE._solved_frames(results, sys; losses = true)
    AEM_COMPARE._check_prices_finite(frames.balance_duals)
    comparison = AEM_COMPARE._compare_range_to_published(db, sys, frames, steps, 0)
    long = _long_comparison(comparison)
    _write_csv(joinpath(out_dir, "comparison_long.csv"), long)
    _write_csv(joinpath(out_dir, "nemde_summary.csv"), _summary(long))
    return
end

function benchmark_highs(out_dir; threads = 1, parallel = "off", hive = joinpath(homedir(), ".nemdb_cache"), n_steps = 6, analysis_level = 384, heuristic_effort = 0.05, time_limit = Inf, rel_gap = 0.0, abs_gap = 1.0e-10)
    isfinite(rel_gap) && rel_gap >= 0 || throw(ArgumentError("rel_gap must be finite and nonnegative"))
    isfinite(abs_gap) && abs_gap >= 0 || throw(ArgumentError("abs_gap must be finite and nonnegative"))
    0.0 <= heuristic_effort <= 1.0 || throw(ArgumentError("heuristic_effort must be between zero and one"))
    time_limit > 0 || throw(ArgumentError("time_limit must be positive"))
    threads >= 0 || throw(ArgumentError("threads must be nonnegative"))
    parallel in ("off", "choose", "on") || throw(ArgumentError("parallel must be off, choose or on"))
    1 <= n_steps <= 12 || throw(ArgumentError("n_steps must be between 1 and 12"))
    ispath(out_dir) && throw(ArgumentError("output directory already exists: $out_dir"))
    mkpath(out_dir)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    try
        open(joinpath(out_dir, "metadata.txt"), "w") do io
            println(io, "source_commit=", readchomp(`git -C $(@__DIR__) rev-parse HEAD`))
            println(io, "julia_version=$VERSION\nhighs_version=", PSI.MOI.get(HiGHS.Optimizer(), PSI.MOI.SolverVersion()))
            println(io, "threads=$threads\nparallel=$parallel\nanalysis_level=$analysis_level\nn_steps_per_window=$n_steps")
            println(io, "mip_heuristic_effort=$heuristic_effort\ntime_limit=$time_limit")
            println(io, "mip_rel_gap=$rel_gap\nmip_abs_gap=$abs_gap\nhive=$hive")
        end
        warmup_steps = DateTime(2026, 1, 1, 4, 5):Minute(5):DateTime(2026, 1, 1, 4, 10)
        warmup_dir = joinpath(out_dir, "warmup")
        println("BENCHMARK warmup ", now()); flush(stdout)
        _measure_warmup(
            db, warmup_steps, warmup_dir;
            time_series_in_memory = true, cache_size_mib = 1024,
            optimizer = _benchmark_optimizer(joinpath(warmup_dir, "solver_logs"), threads, parallel, analysis_level, heuristic_effort, time_limit; rel_gap, abs_gap)
        )
        GC.gc()
        for (name, start) in (("fast", DateTime(2026, 1, 1, 4, 5)), ("slow", DateTime(2026, 1, 1, 17, 20)))
            steps = start:Minute(5):(start + Minute(5) * (n_steps - 1))
            dir = joinpath(out_dir, name)
            optimizer = _benchmark_optimizer(joinpath(dir, "solver_logs"), threads, parallel, analysis_level, heuristic_effort, time_limit; rel_gap, abs_gap)
            println("BENCHMARK start $name ", now()); flush(stdout)
            metrics = measure_replicate_range(db, steps, dir; warmup = false, optimizer, solver_log = true)
            println("BENCHMARK solved $name execute_s=", metrics["execute_s"], " optimize_s=", metrics["per_step_optimize_s"], " pricing_s=", metrics["per_step_dual_pass_s"]); flush(stdout)
            _benchmark_comparison(db, steps, dir)
            GC.gc()
        end
        println("BENCHMARK complete ", now()); flush(stdout)
    finally
        close(db.db)
    end
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    isempty(ARGS) && error("Usage: benchmark_highs.jl out_dir [threads] [parallel] [hive] [n_steps] [analysis_level] [heuristic_effort] [time_limit] [rel_gap] [abs_gap]")
    benchmark_highs(
        ARGS[1];
        threads = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 1,
        parallel = length(ARGS) >= 3 ? ARGS[3] : "off",
        hive = length(ARGS) >= 4 ? ARGS[4] : joinpath(homedir(), ".nemdb_cache"),
        n_steps = length(ARGS) >= 5 ? parse(Int, ARGS[5]) : 6,
        analysis_level = length(ARGS) >= 6 ? parse(Int, ARGS[6]) : 384,
        heuristic_effort = length(ARGS) >= 7 ? parse(Float64, ARGS[7]) : 0.05,
        time_limit = length(ARGS) >= 8 ? parse(Float64, ARGS[8]) : Inf,
        rel_gap = length(ARGS) >= 9 ? parse(Float64, ARGS[9]) : 0.0,
        abs_gap = length(ARGS) >= 10 ? parse(Float64, ARGS[10]) : 1.0e-10
    )
end
