# Run-local measurement wrappers delegate to the original pinned PSI methods.
function _record_interval_measurement(model, phase, stat; solve_s = NaN, pricing_s = NaN, aux_s = NaN)
    folder = PSI.get_output_dir(model)
    row = (;
        timestamp_utc = string(now(UTC)), interval_aest = string(PSI.get_current_time(model)),
        execution_count = PSI.get_execution_count(model), phase,
        wall_s = stat.time, allocated_bytes = stat.bytes, gc_s = stat.gctime,
        compilation_s = hasproperty(stat, :compile_time) ? stat.compile_time : NaN,
        timed_solve_s = solve_s, pricing_s, auxiliary_s = aux_s,
    )
    write_csv(joinpath(folder, "interval_timings.csv"), keys(row), [values(row)]; append = true)
    return
end

function PSI.update_model!(model::PSI.DecisionModel, sim::PSI.Simulation)
    stat = @timed invoke(PSI.update_model!, Tuple{PSI.OperationModel, PSI.Simulation}, model, sim)
    _record_interval_measurement(model, "parameter_update", stat)
    return stat.value
end

function PSI.solve_impl!(model::PSI.DecisionModel)
    stat = @timed invoke(PSI.solve_impl!, Tuple{PSI.OperationModel}, model)
    stats = PSI.get_optimizer_stats(model)
    _record_interval_measurement(
        model, "solve_impl", stat; solve_s = stats.timed_solve_time,
        pricing_s = stats.timed_calculate_dual_variables, aux_s = stats.timed_calculate_aux_variables,
    )
    return stat.value
end

function PSI.write_results!(store, model::PSI.DecisionModel, index::Union{DateTime, Int}, timestamp::DateTime; exports = nothing)
    stat = @timed invoke(
        PSI.write_results!, Tuple{Any, PSI.OperationModel, Union{DateTime, Int}, DateTime},
        store, model, index, timestamp; exports,
    )
    _record_interval_measurement(model, "result_write", stat)
    return stat.value
end
