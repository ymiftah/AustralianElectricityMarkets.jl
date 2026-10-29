module ReplayBatchWorker

using AustralianElectricityMarkets
using AustralianElectricityMarketsSimulations
using DataFrames
using Dates
using DuckDB
using HiGHS
import HDF5
using TOML
using SHA
import PowerSimulations as PSI
using ..ReplayBatchSupport

include("replay_workflow.jl")
using .ReplayWorkflow: replicate_range
using .ReplaySimulation: REPLICATION_MIP_REL_GAP, REPLICATION_MIP_ABS_GAP

function _write_frame(path, frame)
    write_csv(path, names(frame), eachrow(frame))
    return
end

function comparison_summary(comparison)
    rows = NamedTuple[]
    for (metric, table, solved, published) in (
            ("energy_price", :prices, :ROP_solved, :ROP_published),
            ("dispatch_mw", :dispatch, :TOTALCLEARED_solved, :TOTALCLEARED_published),
            ("interconnector_flow_mw", :interconnectors, :MWFLOW_solved, :MWFLOW_published),
            ("interconnector_losses_mw", :interconnectors, :MWLOSSES_solved, :MWLOSSES_published),
            ("fcas_price", :fcas_prices, :ROP_solved, :ROP_published),
        )
        frame = comparison[table]
        gaps = Float64[]
        n_missing, n_nonfinite = 0, 0
        for (a, b) in zip(frame[!, solved], frame[!, published])
            if ismissing(a) || ismissing(b)
                n_missing += 1
            elseif !isfinite(a) || !isfinite(b)
                n_nonfinite += 1
            else
                push!(gaps, a - b)
            end
        end
        paired = length(gaps)
        push!(
            rows, (;
                metric, n_rows = nrow(frame), n_paired = paired, n_missing, n_nonfinite,
                mae = paired == 0 ? missing : sum(abs, gaps) / paired,
                rmse = paired == 0 ? missing : sqrt(sum(abs2, gaps) / paired),
                max_abs_gap = paired == 0 ? missing : maximum(abs, gaps),
                bias = paired == 0 ? missing : sum(gaps) / paired,
            )
        )
    end
    return DataFrame(rows)
end

function save_day(folder, result)
    for table in keys(result.comparison)
        _write_frame(joinpath(folder, "comparison_$table.csv"), result.comparison[table])
    end
    for field in (:chunks, :solver_stats, :skipped_constraints, :constraint_violations, :ramp_violations)
        _write_frame(joinpath(folder, "$field.csv"), result[field])
    end
    _write_frame(joinpath(folder, "summary.csv"), comparison_summary(result.comparison))
    return (;
        intervals = nrow(result.solver_stats), chunks = nrow(result.chunks),
        system_build_s = sum(result.chunks.system_build_s),
        model_build_s = sum(result.chunks.simulation_build_s),
        execute_s = sum(result.chunks.execute_s), compare_s = sum(result.chunks.compare_s),
        solver_s = sum(result.solver_stats.solver_solve_time),
        timed_solve_s = sum(result.solver_stats.timed_solve_time),
        dual_calculation_s = sum(result.solver_stats.timed_calculate_dual_variables),
    )
end

function main(folder, day::Date)
    config = TOML.parsefile(joinpath(folder, "run.toml"))
    day_folder = joinpath(folder, string(day))
    package_root = dirname(dirname(pathof(AustralianElectricityMarkets)))
    actual_revision = try
        readchomp(`git -C $package_root rev-parse HEAD`)
    catch
        "unknown"
    end
    checkout_status = try
        readchomp(`git -C $package_root status --porcelain`)
    catch
        "unknown"
    end
    package_hashes = ReplayBatchSupport.snapshot_package_sources(package_root, joinpath(day_folder, "package_source"))
    time_series_in_memory = parse(Bool, config["time-series-in-memory"])
    provenance = Dict(
        "revision" => actual_revision, "supervisor_revision" => config["git_revision"],
        "time_series_in_memory" => time_series_in_memory,
        "checkout_status" => checkout_status, "package_source_hashes" => package_hashes, "optimization_level" => Int(Base.JLOptions().opt_level),
        "julia" => string(VERSION), "psi" => string(Base.pkgversion(PSI)),
        "highs_package" => string(Base.pkgversion(HiGHS)),
        "hdf5" => string(Base.pkgversion(HDF5)),
        "aem" => string(Base.pkgversion(AustralianElectricityMarkets)),
        "aem_simulations" => string(Base.pkgversion(AustralianElectricityMarketsSimulations)),
        "interval_time_zone" => "fixed AEST UTC+10", "intervention" => 0,
        "mip_rel_gap" => REPLICATION_MIP_REL_GAP, "mip_abs_gap" => REPLICATION_MIP_ABS_GAP,
        "instrumentation" => "interval_timings.csv is read from PSI recorder events and optimizer stats after execute!; TimerOutputs trees in timers_*.toml overlap",
        "source_hashes" => Dict(name => bytes2hex(sha256(read(joinpath(@__DIR__, name)))) for name in readdir(@__DIR__) if endswith(name, ".jl")),
    )
    source_folder = joinpath(day_folder, "runner_source")
    mkpath(source_folder)
    for name in readdir(@__DIR__)
        any(ext -> endswith(name, ext), (".jl", ".py", ".md")) && cp(joinpath(@__DIR__, name), joinpath(source_folder, name))
    end
    cp(joinpath(dirname(dirname(dirname(Base.active_project()))), "Manifest.toml"), joinpath(day_folder, "Manifest.toml"))
    open(joinpath(day_folder, "provenance.toml"), "w") do io
        TOML.print(io, provenance)
    end
    started_ns = parse(UInt64, config["started_ns"])
    elapsed() = (time_ns() - started_ns) / 1.0e9
    optimizer = PSI.optimizer_with_attributes(
        HiGHS.Optimizer, "output_flag" => false, "mip_rel_gap" => REPLICATION_MIP_REL_GAP,
        "mip_abs_gap" => REPLICATION_MIP_ABS_GAP, "threads" => parse(Int, config["solver-threads"]),
    )
    try
        chunk_index = 0
        function on_phase(phase)
            phase == :system_build && (chunk_index += 1)
            if phase in (:execute, :compare)
                label = phase == :execute ? "build" : "execute"
                timer = phase == :execute ? PSI.BUILD_PROBLEMS_TIMER : PSI.RUN_SIMULATION_TIMER
                open(joinpath(day_folder, "timers_$(label)_chunk_$(chunk_index).toml"), "w") do io
                    TOML.print(io, PSI.TimerOutputs.todict(timer))
                end
            end
            write_status(folder, string(phase); trading_day = string(day))
            event = (; timestamp_utc = string(now(UTC)), elapsed_s = elapsed(), trading_day = day, phase)
            write_csv(joinpath(folder, "phases.csv"), keys(event), [values(event)]; append = true)
            println("$(event.timestamp_utc) $day $phase elapsed=$(round(event.elapsed_s; digits = 2))s")
            flush(stdout)
            return
        end
        db = aem_connect(HiveConfiguration(hive_location = config["hive"]))
        try
            steps = trading_steps(day)
            result = replicate_range(
                db, first(steps), last(steps);
                optimizer, output_dir = day_folder, time_series_in_memory,
                cache_size_mib = parse(Int, config["cache-size-mib"]), on_phase
            )
            on_phase(:export)
            totals = save_day(day_folder, result)
            println("Completed $day: $totals")
            flush(stdout)
            open(joinpath(day_folder, "worker_outcome.toml"), "w") do io
                TOML.print(io, Dict(string(k) => v for (k, v) in pairs(totals)))
            end
        finally
            DuckDB.close(db.db)
        end
    catch err
        write(joinpath(day_folder, "worker_error.txt"), sprint(showerror, err, catch_backtrace()) * "\n")
        rethrow()
    end
    return
end

end
