# Three January 6, 2026 intervals from the local cache; no downloads. Run with identical Julia
# flags on each revision, giving a new output folder as the first argument. Add --profile for warmed update profiles. Step 0 is warm-up.
using AustralianElectricityMarkets
using AustralianElectricityMarketsSimulations
using Dates, Logging, TOML, HiGHS, SHA, Profile
import PowerSimulations as PSI
const AEMS = AustralianElectricityMarketsSimulations
function _benchmark_csv_row(io, values)
    println(io, join(("\"" * replace(string(v), "\"" => "\"\"") * "\"" for v in values), ','))
    return
end
function _benchmark_entries(array::PSI.JuMP.Containers.SparseAxisArray)
    return pairs(array.data)
end
function _benchmark_entries(array::PSI.JuMP.Containers.DenseAxisArray)
    return (idx => array[idx...] for idx in Iterators.product(axes(array)...))
end
function _benchmark_entries(array::AbstractArray)
    return (Tuple(idx) => array[idx] for idx in CartesianIndices(array))
end

function _benchmark_updates(folder; profile_updates = false)
    mkdir(folder)
    t = DateTime(2026, 1, 6, 4, 5)
    steps = t:Minute(5):(t + Minute(10))
    println("Building three-interval system"); flush(stdout)
    db = aem_connect()
    system_s = @elapsed sys = prepare_replay_forecasts!(nem_system(db, NEMDEConfiguration(); date_range = t:Minute(5):(last(steps) + Minute(10)), time_series_in_memory = false, time_series_directory = folder))
    optimizer = PSI.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false, "threads" => 1, "mip_rel_gap" => 1.0e-8, "mip_abs_gap" => 1.0e-10)
    println("System built: $system_s seconds; constructing model"); flush(stdout)
    model_s = @elapsed begin
        out = AEMS._range_simulation(sys, steps; optimizer, folder)
        PSI.build!(out.simulation; store_systems_in_results = false, console_level = Logging.Error)
    end
    println("Model built: $model_s seconds; measuring updates"); flush(stdout)
    model = out.model
    container = PSI.get_optimization_container(model)
    results = Dict{String, Any}("system_build_s" => system_s, "model_build_s" => model_s, "julia" => string(VERSION), "optimization_level" => Int(Base.JLOptions().opt_level), "parameter_keys" => length(PSI.get_parameters(model)), "steps" => Any[])
    results["source_hashes"] = Dict(
        file => bytes2hex(sha256(read(joinpath(dirname(pathof(AEMS)), file))))
            for file in ("formulations/fcas.jl", "formulations/generic_constraints.jl", "psi_compat.jl")
    )
    results["psi_version"] = string(Base.pkgversion(PSI))
    results["highs_package_version"] = string(Base.pkgversion(HiGHS))
    results["mip_rel_gap"] = 1.0e-8
    results["mip_abs_gap"] = 1.0e-10
    results["solver_threads"] = 1
    results["intervals_aest"] = string.(collect(steps))
    for i in 0:2
        PSI.set_execution_count!(model, i)
        update_s = @elapsed PSI.update_model!(model, out.simulation)
        solve_s = @elapsed PSI.solve_impl!(model)
        PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED || error("solve failed")
        objective = PSI.get_optimizer_stats(model).objective_value
        row = Dict("step" => i, "update_s" => update_s, "solve_s" => solve_s, "objective" => objective)
        push!(results["steps"], row)
        open(joinpath(folder, "timings.toml"), "w") do io
            TOML.print(io, results)
        end
        point = Dict{PSI.JuMP.VariableRef, Float64}()
        primal_cache = container.primal_values_cache.variables_cache
        open(joinpath(folder, "variables_$i.csv"), "w") do io
            _benchmark_csv_row(io, ("key", "index", "value", "objective_coefficient"))
            objective_function = PSI.JuMP.objective_function(PSI.get_jump_model(model))
            for (key, array) in PSI.get_variables(model)
                for (idx, var) in _benchmark_entries(array)
                    var isa PSI.JuMP.VariableRef || continue
                    value = isempty(primal_cache) ? PSI.JuMP.value(var) : primal_cache[key][idx...]
                    point[var] = value
                    _benchmark_csv_row(io, (PSI.IS.Optimization.encode_key_as_string(key), join(string.(idx), '|'), value, PSI.JuMP.coefficient(objective_function, var)))
                end
            end
        end
        open(joinpath(folder, "duals_$i.csv"), "w") do io
            _benchmark_csv_row(io, ("key", "index", "value"))
            for (key, array) in PSI.get_duals(container)
                for (idx, value) in _benchmark_entries(array)
                    _benchmark_csv_row(io, (PSI.IS.Optimization.encode_key_as_string(key), join(string.(idx), '|'), value))
                end
            end
        end
        jump_model = PSI.get_jump_model(model)
        if length(point) == PSI.JuMP.num_variables(jump_model)
            residuals = PSI.JuMP.primal_feasibility_report(jump_model, point; atol = 0.0)
            row["max_primal_residual_pu"] = maximum(values(residuals); init = 0.0)
            row["evaluated_objective"] = PSI.JuMP.value(v -> point[v], PSI.JuMP.objective_function(jump_model))
        else
            row["unmapped_variables"] = PSI.JuMP.num_variables(jump_model) - length(point)
        end
        open(joinpath(folder, "timings.toml"), "w") do io
            TOML.print(io, results)
        end
        println("STEP $i $row"); flush(stdout)
    end
    profile_updates && _profile_recurrent_updates!(model, out.simulation, folder)
    return
end
# Repeated reads at the final timestamp isolate warmed update work from solves and cache fills.
function _profile_recurrent_updates!(model, simulation, folder)
    container = PSI.get_optimization_container(model)
    state = PSI.get_simulation_state(simulation)
    open(joinpath(folder, "update_families.csv"), "w") do io
        _benchmark_csv_row(io, ("repetition", "family", "component", "meta", "seconds", "allocated_bytes", "gc_seconds"))
        for repetition in 0:3
            PSI.cost_function_unsynch(container)
            for key in keys(PSI.get_parameters(model))
                stat = @timed PSI.update_parameter_values!(model, key, state)
                _benchmark_csv_row(
                    io, (
                        repetition, PSI.IS.Optimization.get_entry_type(key), PSI.IS.Optimization.get_component_type(key),
                        key.meta, stat.time, stat.bytes, stat.gctime,
                    )
                )
            end
            stat = @timed PSI.update_objective_function!(container)
            PSI.set_synchronized_status!(PSI.get_objective_expression(container), true)
            _benchmark_csv_row(io, (repetition, "objective_install", "", "", stat.time, stat.bytes, stat.gctime))
        end
    end
    open(joinpath(folder, "warmed_updates.csv"), "w") do io
        _benchmark_csv_row(io, ("repetition", "seconds", "allocated_bytes", "gc_seconds"))
        for repetition in 0:5
            stat = @timed PSI.update_model!(model, simulation)
            _benchmark_csv_row(io, (repetition, stat.time, stat.bytes, stat.gctime))
        end
    end
    Profile.clear()
    Profile.init(; n = 2_000_000, delay = 0.002)
    Profile.@profile for _ in 1:5
        PSI.update_model!(model, simulation)
    end
    for format in (:flat, :tree)
        open(joinpath(folder, "update_cpu_$format.txt"), "w") do io
            output = IOContext(io, :displaysize => (200, 240))
            if format == :flat
                Profile.print(output; format, sortedby = :count, mincount = 5, C = true)
            else
                Profile.print(output; format, mincount = 10, C = true)
            end
        end
    end
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    with_logger(ConsoleLogger(stderr, Logging.Error)) do
        _benchmark_updates(ARGS[1]; profile_updates = "--profile" in ARGS[2:end])
    end
end
