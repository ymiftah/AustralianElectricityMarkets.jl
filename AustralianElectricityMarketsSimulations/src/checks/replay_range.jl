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
  recorded with, in addition to the constraints unavailable from the build (see [`get_unavailable_constraints`](@ref)).

# Returns
A `DataFrame` with columns `constraint`, `reason` and `n_missing`, one row per constraint left out of the replay:
the unavailable constraints of `sys`, with `n_missing = 0`, and the `GenericConstraint`s excluded here. Sorted by
constraint name. Throws `ArgumentError` when a pre-flight check fails.
"""
function prepare_replay!(
        sys::PSY.System, template::PSI.ProblemTemplate, steps::StepRange{DateTime};
        exclude_constraints::AbstractDict{<:AbstractString, Symbol} = Dict{String, Symbol}(),
    )
    rows = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int}[
        (constraint = r.constraint, reason = r.reason, n_missing = 0) for r in eachrow(get_unavailable_constraints(sys))
    ]
    append!(rows, exclude_unmodeled_services!(sys, template; exclude_constraints))
    sort!(rows; by = r -> r.constraint)
    check_dispatch_envelope(template, sys, first(steps), length(steps))
    return DataFrame(rows)
end
