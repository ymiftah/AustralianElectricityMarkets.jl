# Available `GenericConstraint`s invoked at none of `steps`, each mapped to `:never_invoked`.
function _never_invoked_constraints(sys::PSY.System, steps)
    reasons = Dict{String, Symbol}()
    for gc in PSY.get_components(PSY.get_available, GenericConstraint, sys)
        invoked = PSY.get_time_series_values(
            PSY.SingleTimeSeries, gc, "invoked"; start_time = first(steps), len = length(steps),
        )
        all(iszero, invoked) && (reasons[PSY.get_name(gc)] = :never_invoked)
    end
    return reasons
end


# Validates the requested forecast windows using attached system metadata only.
function _check_replication_steps(sys::PSY.System, steps::StepRange{DateTime})
    (!isempty(steps) && step(steps) == DISPATCH_INTERVAL) || throw(
        ArgumentError("replication_simulation: steps must be a non-empty range of five-minute intervals."),
    )
    PSY.get_time_series_counts(sys).forecast_count > 0 || throw(
        ArgumentError("replication_simulation: call prepare_replication!(sys) before constructing a simulation."),
    )
    missing_steps = setdiff(steps, PSY.get_forecast_initial_times(sys))
    isempty(missing_steps) || throw(
        ArgumentError("replication_simulation: attached forecasts do not cover $(first(missing_steps)); construct a system covering the requested range."),
    )
    return
end


# Constructs the simulation and retains its model and skipped-constraint report for internal callers.
function _range_simulation(
        sys::PSY.System, steps::StepRange{DateTime}; optimizer = _DEFAULT_OPTIMIZER, parts = REPLICATION_PARTS,
        folder::AbstractString = mktempdir(), name = "dispatch", skipped = nothing,
    )
    _check_replication_steps(sys, steps)
    :tie_breaks in parts && check_tie_break_pairs(sys, steps)
    template_skipped = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int}[]
    exclude = :generic_constraints in parts ? _never_invoked_constraints(sys, steps) : Dict{String, Symbol}()
    template = replication_template(sys; skipped = template_skipped, parts = parts, exclude_constraints = exclude)
    isnothing(skipped) || append!(skipped, template_skipped)
    skipped_constraints = DataFrame(template_skipped)
    check_fcas_services(sys, template; excluded_device_types = :batteries in parts ? () : (PSY.Storage,))
    check_dispatch_envelope(sys, template, first(steps), length(steps))
    model = _replication_decision_model(template, sys, first(steps); optimizer = optimizer, name = name)
    models = PSI.SimulationModels(; decision_models = [model])
    sequence = PSI.SimulationSequence(; models = models, ini_cond_chronology = PSI.InterProblemChronology())
    simulation = PSI.Simulation(;
        name = "replicate_range", steps = length(steps), models = models,
        sequence = sequence, simulation_folder = folder, initial_time = first(steps),
    )
    return (; simulation, model, skipped_constraints)
end


"""
    replication_simulation(sys::PSY.System, steps; optimizer, parts = REPLICATION_PARTS,
        folder = mktempdir(), name = "dispatch", skipped = nothing) -> PSI.Simulation

Constructs an unbuilt PSI simulation over `steps` from a prepared system. Runs the replay
pre-flight checks and selects constraints invoked in at least one requested interval.

# Arguments
- `sys`: a system prepared with [`prepare_replication!`](@ref), or equivalent attached forecasts.
- `steps`: a non-empty range of five-minute interval-ending timestamps covered by the system.
- `optimizer`: the JuMP optimizer; defaults to HiGHS with zero MIP gaps.
- `parts`: the [`REPLICATION_PARTS`](@ref) included in the model.
- `folder`: the simulation output directory.
- `name`: the decision problem name used to retrieve PSI results.
- `skipped`: an optional vector receiving `(constraint, reason, n_missing)` records.

# Returns
A `PSI.Simulation` for `PSI.build!` and `PSI.execute!`. Throws `ArgumentError` for invalid ranges
or missing inputs or incompatible tie-break pairs.
"""
function replication_simulation(sys::PSY.System, steps::StepRange{DateTime}; kwargs...)
    return _range_simulation(sys, steps; kwargs...).simulation
end


# Builds a system-only simulation for internal callers that also need its model and skip report.
function _build_range_simulation(sys::PSY.System, steps::StepRange{DateTime}; kwargs...)
    out = _range_simulation(sys, steps; kwargs...)
    status = Base.CoreLogging.with_logger(
        () -> PSI.build!(out.simulation; store_systems_in_results = false), _DropMILPWarning(),
    )
    status == PSI.SimulationBuildStatus.BUILT || begin
        _log_skipped_constraints(out.skipped_constraints)
        error("Range from $(first(steps)) failed to build ($status); see the simulation logs.")
    end
    return out
end


# Executes a built simulation and returns the results of its decision problem `name`.
function _execute_range_simulation(simulation::PSI.Simulation; name = "dispatch", cache_size_mib = nothing)
    kwargs = isnothing(cache_size_mib) ? (;) : (; cache_size_mib = cache_size_mib)
    status = PSI.execute!(simulation; kwargs...)
    status == PSI.RunStatus.SUCCESSFULLY_FINALIZED ||
        error("Range from $(PSI.get_initial_time(simulation)) failed to execute ($status); see the simulation logs.")
    return PSI.get_decision_problem_results(PSI.SimulationResults(simulation), name)
end


# Builds and executes one `PSI.Simulation` of a one-interval `DecisionModel` over `steps`.
function _replication_simulation(
        sys::PSY.System, steps; optimizer = _DEFAULT_OPTIMIZER, parts = REPLICATION_PARTS,
        folder::AbstractString = mktempdir(), cache_size_mib = nothing,
    )
    (; simulation, model, skipped_constraints) =
        _build_range_simulation(sys, steps; optimizer = optimizer, parts = parts, folder = folder)
    results = try
        _execute_range_simulation(simulation; cache_size_mib = cache_size_mib)
    catch
        _log_skipped_constraints(skipped_constraints)
        rethrow()
    end
    return (; simulation, model, results, skipped_constraints)
end
