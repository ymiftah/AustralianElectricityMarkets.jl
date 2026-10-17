# Compare MIP solvers on cached replay windows with a shared HiGHS pricing LP.
# Use a temporary environment containing the pinned test dependencies plus SCIP and Cbc.
# julia --project=<benchmark_environment> --threads=1 benchmark_solvers.jl out_dir highs|scip|cbc [n_steps=6] [time_limit=180] [clear_mip_starts=false]
include(joinpath(@__DIR__, "benchmark_highs.jl"))
using SCIP, Cbc, SHA, Serialization, LinearAlgebra

function _comparison_solver_options(label, time_limit)
    if label == "highs"
        return (
            "threads" => 1, "parallel" => "off", "mip_rel_gap" => 0.0,
            "mip_abs_gap" => 1.0e-10, "time_limit" => time_limit,
            "primal_feasibility_tolerance" => 1.0e-7, "dual_feasibility_tolerance" => 1.0e-7,
            "mip_feasibility_tolerance" => 1.0e-7, "output_flag" => true,
        )
    elseif label == "scip"
        return (
            "parallel/maxnthreads" => 1, "lp/threads" => 1,
            "limits/gap" => 0.0, "limits/absgap" => 1.0e-10,
            "limits/time" => time_limit, "numerics/feastol" => 1.0e-7,
            "numerics/dualfeastol" => 1.0e-7, "display/verblevel" => 4,
        )
    elseif label == "cbc"
        return (
            "threads" => 1, "ratioGap" => 0.0, "allowableGap" => 1.0e-10,
            "seconds" => time_limit, "primalTolerance" => 1.0e-7,
            "dualTolerance" => 1.0e-7, "integerTolerance" => 1.0e-7, "logLevel" => 1,
        )
    end
    throw(ArgumentError("solver must be highs, scip or cbc"))
end

function _comparison_optimizer(label, time_limit)
    constructor = label == "highs" ? HiGHS.Optimizer : label == "scip" ? SCIP.Optimizer : Cbc.Optimizer
    return PSI.JuMP.optimizer_with_attributes(constructor, _comparison_solver_options(label, time_limit)...)
end

function _comparison_matrix_fingerprint(model)
    data = PSI.JuMP.lp_matrix_data(model)
    io = IOBuffer()
    Serialization.serialize(
        io, (
            data.A.colptr, data.A.rowval, data.A.nzval, data.b_lower, data.b_upper,
            data.x_lower, data.x_upper, data.c, data.c_offset, data.integers, data.binaries, data.sense,
        )
    )
    return bytes2hex(sha256(take!(io)))
end

function _comparison_residuals(model)
    data = PSI.JuMP.lp_matrix_data(model)
    values = PSI.JuMP.value.(data.variables)
    all(isfinite, values) || error("Solver returned a non-finite variable value")
    activity = data.A * values
    row = maximum(max.(data.b_lower - activity, activity - data.b_upper, 0.0); init = 0.0)
    bound = maximum(max.(data.x_lower - values, values - data.x_upper, 0.0); init = 0.0)
    discrete = values[unique(vcat(data.integers, data.binaries))]
    integer = maximum(abs.(discrete - round.(discrete)); init = 0.0)
    return (; row, bound, integer)
end

function _comparison_solve_hook(label, out_dir, time_limit; clear_mip_starts = false)
    mkpath(out_dir)
    file = joinpath(out_dir, "solves.csv")
    write(file, "call,phase,solver,rows,columns,binaries,fingerprint,fingerprint_s,optimize_wall_s,solver_s,termination_status,primal_status,objective,bound,node_count,row_violation,bound_violation,integrality_violation,evaluated_objective,pricing_improvement\n")
    calls = Ref(0)
    dispatch_objective = Ref(NaN)
    function hook(model; kwargs...)
        calls[] += 1
        binaries = PSI.JuMP.num_constraints(model, PSI.JuMP.VariableRef, PSI.MOI.ZeroOne)
        integers = PSI.JuMP.num_constraints(model, PSI.JuMP.VariableRef, PSI.MOI.Integer)
        phase = binaries + integers > 0 ? "MIP" : "LP"
        solver = phase == "MIP" ? label : "highs"
        if phase == "MIP" && clear_mip_starts
            PSI.JuMP.set_start_value.(PSI.JuMP.all_variables(model), nothing)
        end
        objective_function = PSI.JuMP.objective_function(model)
        fingerprint = ""
        fingerprint_s = phase == "MIP" ? @elapsed(fingerprint = _comparison_matrix_fingerprint(model)) : 0.0
        rows = PSI.JuMP.num_constraints(model; count_variable_in_set_constraints = false)
        columns = PSI.JuMP.num_variables(model)
        wall_s = @elapsed begin
            PSI.JuMP.set_optimizer(model, _comparison_optimizer(solver, time_limit))
            PSI.JuMP.optimize!(model; ignore_optimize_hook = true, kwargs...)
        end
        status = PSI.JuMP.termination_status(model)
        primal = PSI.JuMP.primal_status(model)
        objective = PSI.JuMP.has_values(model) ? PSI.JuMP.objective_value(model) : NaN
        evaluated_objective = PSI.JuMP.has_values(model) ? PSI.JuMP.value(objective_function) : NaN
        pricing_improvement = phase == "LP" ? dispatch_objective[] - objective : 0.0
        phase == "MIP" && (dispatch_objective[] = objective)
        bound = PSI.JuMP.objective_bound(model)
        solver_s = PSI.JuMP.solve_time(model)
        nodes = phase == "MIP" ? PSI.MOI.get(PSI.JuMP.backend(model), PSI.MOI.NodeCount()) : 0
        residuals = PSI.JuMP.has_values(model) ? _comparison_residuals(model) : (; row = NaN, bound = NaN, integer = NaN)
        open(file, "a") do io
            println(io, join((calls[], phase, solver, rows, columns, binaries, fingerprint, fingerprint_s, wall_s, solver_s, status, primal, objective, bound, nodes, residuals.row, residuals.bound, residuals.integer, evaluated_objective, pricing_improvement), ","))
        end
        status == PSI.MOI.OPTIMAL || error("$solver $phase stopped with $status; benchmark rejects this solve")
        isfinite(objective) || error("$solver $phase returned a non-finite objective")
        max(residuals.row, residuals.bound, residuals.integer) <= 1.0e-6 || error("$solver $phase exceeds the common feasibility check: $residuals")
        tolerance = 1.0e-5 + 1.0e-9 * max(abs(objective), abs(evaluated_objective))
        abs(objective - evaluated_objective) <= tolerance || error("Native objective disagrees with the original objective expression")
        phase == "LP" && abs(pricing_improvement) > tolerance && error("Fixed-binary pricing objective disagrees with dispatch by $pricing_improvement")
        phase == "LP" && !PSI.JuMP.has_duals(model) && error("Pricing LP has no dual solution")
        return
    end
    return hook
end

function _comparison_model_hook(label, out_dir, time_limit; clear_mip_starts = false)
    function configure(model)
        container = PSI.get_optimization_container(model)
        PSI.JuMP.set_optimize_hook(PSI.get_jump_model(container), _comparison_solve_hook(label, out_dir, time_limit; clear_mip_starts))
        return
    end
    return configure
end

function benchmark_solvers(out_dir, label; n_steps = 6, time_limit = 180.0, clear_mip_starts = false)
    label in ("highs", "scip", "cbc") || throw(ArgumentError("solver must be highs, scip or cbc"))
    1 <= n_steps <= 6 || throw(ArgumentError("n_steps must be between one and six"))
    time_limit > 0 || throw(ArgumentError("time_limit must be positive"))
    ispath(out_dir) && throw(ArgumentError("output directory already exists: $out_dir"))
    mkpath(out_dir)
    BLAS.set_num_threads(1)
    optimizer = _comparison_optimizer(label, time_limit)
    native = PSI.MOI.instantiate(optimizer)
    open(joinpath(out_dir, "metadata.txt"), "w") do io
        println(io, "source_commit=", readchomp(`git -C $(@__DIR__) rev-parse HEAD`))
        println(io, "julia_version=$VERSION\nsolver=$label\nsolver_version=", PSI.MOI.get(native, PSI.MOI.SolverVersion()))
        println(io, "pricing_solver=highs\npricing_solver_version=", PSI.MOI.get(HiGHS.Optimizer(), PSI.MOI.SolverVersion()))
        println(io, "clear_mip_starts=$clear_mip_starts")
        println(io, "threads=1\nblas_threads=1\nn_steps_per_window=$n_steps\ntime_limit=$time_limit\nmip_rel_gap=0.0\nmip_abs_gap=1e-10\nfeasibility_tolerance=1e-7")
        for (key, expected) in _comparison_solver_options(label, time_limit)
            actual = PSI.MOI.get(native, PSI.MOI.RawOptimizerAttribute(key))
            string(actual) == string(expected) || error("Option read-back differs: $key: $actual != $expected")
            println(io, key, "=", actual)
        end
    end
    db = aem_connect(HiveConfiguration(hive_location = joinpath(homedir(), ".nemdb_cache")))
    failures = String[]
    try
        steps = DateTime(2026, 1, 1, 4, 5):Minute(5):DateTime(2026, 1, 1, 4, 10)
        warmup = joinpath(out_dir, "warmup")
        println("BENCHMARK warmup $label ", now()); flush(stdout)
        _measure_warmup(db, steps, warmup; time_series_in_memory = true, optimizer, cache_size_mib = 1024, model_hook = _comparison_model_hook(label, warmup, time_limit; clear_mip_starts))
        GC.gc()
        for (window, start) in (("fast", DateTime(2026, 1, 1, 4, 5)), ("slow", DateTime(2026, 1, 1, 17, 20)))
            steps = start:Minute(5):(start + Minute(5) * (n_steps - 1))
            dir = joinpath(out_dir, window)
            println("BENCHMARK start $label $window ", now()); flush(stdout)
            try
                metrics = measure_replicate_range(db, steps, dir; warmup = false, optimizer, solver_log = true, model_hook = _comparison_model_hook(label, dir, time_limit; clear_mip_starts))
                println("BENCHMARK solved $label $window execute_s=", metrics["execute_s"], " optimize_s=", metrics["per_step_optimize_s"], " pricing_s=", metrics["per_step_dual_pass_s"]); flush(stdout)
                _benchmark_comparison(db, steps, dir)
            catch err
                push!(failures, window)
                write(joinpath(dir, "failure.txt"), sprint(showerror, err, catch_backtrace()))
                println("BENCHMARK failed $label $window: ", sprint(showerror, err)); flush(stdout)
            end
            GC.gc()
        end
    finally
        close(db.db)
    end
    isempty(failures) || error("Benchmark failed windows: $(join(failures, ", "))")
    println("BENCHMARK complete $label ", now()); flush(stdout)
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) >= 2 || error("Usage: benchmark_solvers.jl out_dir highs|scip|cbc [n_steps] [time_limit] [clear_mip_starts]")
    benchmark_solvers(ARGS[1], ARGS[2]; n_steps = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 6, time_limit = length(ARGS) >= 4 ? parse(Float64, ARGS[4]) : 180.0, clear_mip_starts = length(ARGS) >= 5 ? parse(Bool, ARGS[5]) : false)
end
