module ReplayBatchWorker

using AustralianElectricityMarkets
using AustralianElectricityMarketsSimulations
using DataFrames
using Dates
using DuckDB
using HiGHS
using TOML
import PowerSimulations as PSI
using ..ReplayBatchSupport

include("replay_workflow.jl")
using .ReplayWorkflow: replicate_range

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

function main(folder)
    config = TOML.parsefile(joinpath(folder, "run.toml"))
    started_ns = parse(UInt64, config["started_ns"])
    elapsed() = (time_ns() - started_ns) / 1.0e9
    days = scheduled_days(Date(config["first"]), Date(config["last"]), parse(Int, config["seed"]))
    budget_s = 3600 * parse(Float64, config["hours"])
    optimizer = PSI.optimizer_with_attributes(
        HiGHS.Optimizer, "output_flag" => false, "mip_rel_gap" => 1.0e-8,
        "mip_abs_gap" => 1.0e-10, "threads" => parse(Int, config["solver-threads"]),
    )
    outcome = run_schedule(folder, days, budget_s; elapsed) do day, day_folder
        function on_phase(phase)
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
                optimizer, output_dir = day_folder, time_series_in_memory = false,
                cache_size_mib = parse(Int, config["cache-size-mib"]), on_phase
            )
            on_phase(:export)
            totals = save_day(day_folder, result)
            println("Completed $day: $totals")
            flush(stdout)
            return totals
        finally
            DuckDB.close(db.db)
        end
    end
    write_status(folder, "finished"; details = "$(outcome.reason): completed=$(outcome.completed) failed=$(outcome.failed)")
    open(joinpath(folder, "outcome.toml"), "w") do io
        TOML.print(
            io, Dict(
                "completed" => outcome.completed, "failed" => outcome.failed,
                "reason" => outcome.reason, "elapsed_s" => elapsed()
            )
        )
    end
    outcome.completed > 0 || error("No trading days completed; inspect failures.csv and per-day error.txt files")
    return
end

end
