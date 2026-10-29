# Simulation runner for replay dispatch: constructs, builds and executes the one-interval replication
# model of a range of intervals, and logs the skipped constraints of a failed run. Included by the
# replay workflow and the simulation tests.

module ReplaySimulation

using AustralianElectricityMarketsSimulations
using DataFrames
using Dates
using HiGHS
using PowerSimulations: optimizer_with_attributes
import PowerSimulations as PSI
import PowerSystems as PSY

export replication_simulation, run_replication, REPLICATION_OPTIMIZER, REPLICATION_MIP_REL_GAP, REPLICATION_MIP_ABS_GAP,
    REPLICATION_HIGHS_OPTIONS

"""
    REPLICATION_MIP_REL_GAP

The HiGHS relative MIP gap of the replay optimizer, shared with the batch runner.
"""
const REPLICATION_MIP_REL_GAP = 1.0e-8

"""
    REPLICATION_MIP_ABS_GAP

The HiGHS absolute MIP gap of the replay optimizer, shared with the batch runner.
"""
const REPLICATION_MIP_ABS_GAP = 1.0e-10

"""
    REPLICATION_HIGHS_OPTIONS

The HiGHS options shared by every replay optimizer: the MIP gaps and the root sub-MIP heuristics
turned off (RINS, RENS, root reduced-cost and feasibility jump).
"""
const REPLICATION_HIGHS_OPTIONS = (
    "mip_rel_gap" => REPLICATION_MIP_REL_GAP,
    "mip_abs_gap" => REPLICATION_MIP_ABS_GAP,
    "mip_heuristic_run_rins" => false,
    "mip_heuristic_run_rens" => false,
    "mip_heuristic_run_root_reduced_cost" => false,
    "mip_heuristic_run_feasibility_jump" => false,
)

"""
    REPLICATION_OPTIMIZER

The default replay optimizer: HiGHS with the options of [`REPLICATION_HIGHS_OPTIONS`](@ref), a
1e-8 relative and 1e-10 absolute MIP gap, since the interconnector loss encoding makes each
interval a MILP. Root sub-MIP heuristics are off because they only search for better incumbents
after the optimum is found and dominate solve time on slow intervals.
"""
const REPLICATION_OPTIMIZER = optimizer_with_attributes(HiGHS.Optimizer, REPLICATION_HIGHS_OPTIONS...)


# Drops PSI's per-container "resulted in a MILP" warning, emitted once per dual container.
struct _DropMILPWarning <: Base.CoreLogging.AbstractLogger
    inner::Base.CoreLogging.AbstractLogger
end

_DropMILPWarning() = _DropMILPWarning(Base.CoreLogging.current_logger())

Base.CoreLogging.min_enabled_level(l::_DropMILPWarning) = Base.CoreLogging.min_enabled_level(l.inner)

Base.CoreLogging.shouldlog(l::_DropMILPWarning, args...) = Base.CoreLogging.shouldlog(l.inner, args...)

Base.CoreLogging.catch_exceptions(l::_DropMILPWarning) = Base.CoreLogging.catch_exceptions(l.inner)

function Base.CoreLogging.handle_message(l::_DropMILPWarning, level, message, args...; kwargs...)
    occursin("resulted in a MILP", string(message)) && return nothing
    return Base.CoreLogging.handle_message(l.inner, level, message, args...; kwargs...)
end


# Logs the skipped-constraint count by reason and the table, for a build or solve that failed.
function _log_skipped_constraints(skipped::DataFrame)
    by_reason = combine(groupby(skipped, :reason), nrow => :n)
    counts = join(("$(r.reason)=$(r.n)" for r in eachrow(sort(by_reason, :reason))), ", ")
    @error "Skipped constraints at failure: $(nrow(skipped)) ($counts)" skipped
    return
end


# Constructs the simulation and retains its model and skipped-constraint report for internal callers.
function _range_simulation(
        sys::PSY.System, steps::StepRange{DateTime}; optimizer = REPLICATION_OPTIMIZER, parts = REPLICATION_PARTS,
        folder::AbstractString = mktempdir(), name = "dispatch", simulation_name = "replication", skipped = nothing,
    )
    check_replication_steps(sys, steps)
    check_single_financial_year(steps)
    :tie_breaks in parts && check_tie_break_pairs(sys, steps)
    template_skipped = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int}[]
    exclude = :generic_constraints in parts ? never_invoked_constraints(sys, steps) : Dict{String, Symbol}()
    template = replication_template(
        sys; initial_time = first(steps), skipped = template_skipped, parts = parts, exclude_constraints = exclude,
    )
    isnothing(skipped) || append!(skipped, template_skipped)
    skipped_constraints = DataFrame(template_skipped)
    check_fcas_services(sys, template; excluded_device_types = :batteries in parts ? () : (PSY.Storage,))
    check_dispatch_envelope(sys, template, first(steps), length(steps))
    model = replication_decision_model(template, sys, first(steps); optimizer = optimizer, name = name)
    models = PSI.SimulationModels(; decision_models = [model])
    sequence = PSI.SimulationSequence(; models = models, ini_cond_chronology = PSI.InterProblemChronology())
    simulation = PSI.Simulation(;
        name = simulation_name, steps = length(steps), models = models,
        sequence = sequence, simulation_folder = folder, initial_time = first(steps),
    )
    return (; simulation, model, skipped_constraints)
end


"""
    replication_simulation(sys::PSY.System, steps; optimizer = REPLICATION_OPTIMIZER, parts = REPLICATION_PARTS,
        folder = mktempdir(), name = "dispatch", simulation_name = "replication",
        skipped = nothing) -> PSI.Simulation

Constructs an unbuilt PSI simulation over `steps` from a prepared system. Runs the replay
pre-flight checks and selects constraints invoked in at least one requested interval.

# Arguments
- `sys`: a system prepared with `prepare_replay_forecasts!`, or equivalent attached forecasts.
- `steps`: a non-empty range of five-minute interval-ending timestamps covered by the system.
- `optimizer`: the JuMP optimizer; defaults to HiGHS with the gaps and heuristic settings of `REPLICATION_HIGHS_OPTIONS`.
- `parts`: the `REPLICATION_PARTS` included in the model.
- `folder`: the simulation output directory.
- `name`: the decision problem name used to retrieve PSI results.
- `simulation_name`: the PSI simulation name, used to reopen results with `PSI.SimulationResults(folder, simulation_name)`.
- `skipped`: an optional vector receiving `(constraint, reason, n_missing)` records.

# Returns
A `PSI.Simulation` for `PSI.build!` and `PSI.execute!`. Throws `ArgumentError` for invalid ranges
or missing inputs, or incompatible tie-break pairs.
"""
function replication_simulation(sys::PSY.System, steps::StepRange{DateTime}; kwargs...)
    return _range_simulation(sys, steps; kwargs...).simulation
end


"""
    run_replication(sys::PSY.System, steps; name = "dispatch", cache_size_mib = nothing, on_phase = nothing, kwargs...) -> NamedTuple

Builds and executes the [`replication_simulation`](@ref) of `sys` over `steps`, logging the
skipped constraints when the build or execution fails.

# Arguments
- `sys`, `steps`: as for [`replication_simulation`](@ref).
- `name`: the decision problem name, whose results are returned.
- `cache_size_mib`: the PSI results cache size, or `nothing` for PSI's default.
- `kwargs`: the other [`replication_simulation`](@ref) keywords.
- `on_phase`: optional callback receiving `:model_build` and `:execute` before each phase.

# Returns
`(; simulation, model, results, skipped_constraints, timings)`: the executed `PSI.Simulation`, its
`DecisionModel`, the decision problem's `PSI.SimulationProblemResults`, the skipped constraints as a
`DataFrame`, and `(; build_s, execute_s)` wall-clock seconds, `build_s` including construction. Throws when the build or execution
does not succeed.
"""
function run_replication(
        sys::PSY.System, steps::StepRange{DateTime}; name = "dispatch", cache_size_mib = nothing, on_phase = nothing, kwargs...,
    )
    isnothing(on_phase) || on_phase(:model_build)
    t0 = time()
    (; simulation, model, skipped_constraints) = _range_simulation(sys, steps; name = name, kwargs...)
    status = Base.CoreLogging.with_logger(
        () -> PSI.build!(simulation; store_systems_in_results = false), _DropMILPWarning(),
    )
    build_s = time() - t0
    if status != PSI.SimulationBuildStatus.BUILT
        _log_skipped_constraints(skipped_constraints)
        error("Range from $(first(steps)) failed to build ($status); see the simulation logs.")
    end
    isnothing(on_phase) || on_phase(:execute)
    t1 = time()
    status = try
        PSI.execute!(simulation; (isnothing(cache_size_mib) ? (;) : (; cache_size_mib))...)
    catch
        _log_skipped_constraints(skipped_constraints)
        rethrow()
    end
    execute_s = time() - t1
    if status != PSI.RunStatus.SUCCESSFULLY_FINALIZED
        _log_skipped_constraints(skipped_constraints)
        error("Range from $(first(steps)) failed to execute ($status); see the simulation logs.")
    end
    results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), name)
    return (; simulation, model, results, skipped_constraints, timings = (; build_s, execute_s))
end

end
