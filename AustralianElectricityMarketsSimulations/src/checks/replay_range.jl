"""
    prepare_replay!(sys::PSY.System, template::PSI.ProblemTemplate, steps::StepRange{DateTime};
        exclude_constraints::AbstractDict{<:AbstractString, Symbol} = Dict{String, Symbol}()) -> DataFrame

Prepares `sys` for a replay of `template` over `steps`: runs the replay pre-flight checks and excludes the
constraints the template cannot model. Each call on the same system replaces the exclusions of the previous
call, as [`exclude_unmodeled_services!`](@ref) does. The forecast windows are attached by [`nem_system`](@ref).

# Arguments
- `sys`: the replay system, mutated in place: its availability changes.
- `template`: the `PSI.ProblemTemplate` the replay builds, e.g. [`template_nemde`](@ref)().
- `steps`: a non-empty range of five-minute interval-ending timestamps within the replay intervals of `sys`.
- `exclude_constraints`: a `Dict` from the names of `GenericConstraint`s of `sys` to the `reason` each is
  recorded with, in addition to the constraints never invoked in `steps`.

# Returns
A `DataFrame` with columns `constraint`, `reason` and `n_missing`, one row per excluded `GenericConstraint`,
sorted by constraint name. Throws `ArgumentError` when a pre-flight check fails.
"""
function prepare_replay!(
        sys::PSY.System, template::PSI.ProblemTemplate, steps::StepRange{DateTime};
        exclude_constraints::AbstractDict{<:AbstractString, Symbol} = Dict{String, Symbol}(),
    )
    exclude = _has_service_model(template, GenericConstraint) ?
        merge(never_invoked_constraints(sys, steps), exclude_constraints) : Dict{String, Symbol}(exclude_constraints)
    skipped = DataFrame(exclude_unmodeled_services!(sys, template; exclude_constraints = exclude))
    check_dispatch_envelope(template, sys, first(steps), length(steps))
    return skipped
end


"""
    never_invoked_constraints(sys, steps) -> Dict{String, Symbol}

Maps each `GenericConstraint` of `sys`, available or not, that is invoked in none of `steps` to
`:never_invoked`, the `exclude_constraints` reason of [`exclude_unmodeled_services!`](@ref). Constraints
excluded by an earlier call are unavailable, so they are included to be reported again on a reused system.

# Arguments
- `sys`: the system prepared by [`prepare_replay!`](@ref), whose constraints carry an invoked series.
- `steps`: the interval-ending timestamps the simulation solves.

# Returns
A `Dict` from constraint name to `:never_invoked`; empty when every constraint is invoked in some interval.
"""
function never_invoked_constraints(sys::PSY.System, steps)
    reasons = Dict{String, Symbol}()
    for gc in PSY.get_components(GenericConstraint, sys)
        invoked::Vector{Float64} = IS.get_time_series_values(
            gc, _constraint_key(gc, :invoked, NEM_CONSTRAINT_SERIES.invoked);
            start_time = first(steps), len = length(steps),
        )
        all(iszero, invoked) && (reasons[PSY.get_name(gc)] = :never_invoked)
    end
    return reasons
end
