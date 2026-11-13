"""
    _prepare_replay_forecasts!(sys::PSY.System) -> PSY.System

Transforms the single time series of a system built by [`nem_system`](@ref) into five-minute
forecast windows of one interval each. Returns `sys` unchanged when it already has forecasts.

# Arguments
- `sys`: a system with at least two timestamps of single time series.

# Returns
The modified system. Throws `ArgumentError` when input series are absent or fewer than two timestamps exist.
"""
function _prepare_replay_forecasts!(sys::PSY.System)
    counts = PSY.get_time_series_counts(sys)
    counts.forecast_count == 0 || return sys
    counts.static_time_series_count > 0 ||
        throw(ArgumentError("_prepare_replay_forecasts!: attach input time series before preparation."))
    _, n = PSY.check_time_series_consistency(sys, PSY.SingleTimeSeries)
    n >= 2 || throw(ArgumentError("_prepare_replay_forecasts!: at least two input timestamps are required for forecast windows."))
    PSY.transform_single_time_series!(sys, DISPATCH_INTERVAL, DISPATCH_INTERVAL)
    return sys
end


"""
    prepare_replay!(sys::PSY.System, template::PSI.ProblemTemplate, steps::StepRange{DateTime};
        exclude_constraints::AbstractDict{<:AbstractString, Symbol} = Dict{String, Symbol}()) -> DataFrame

Prepares `sys` for a replay of `template` over `steps`: attaches the five-minute forecast windows on the
first call, runs the replay pre-flight checks and excludes the constraints the template cannot model. Each call
on the same system replaces the exclusions of the previous call, as [`exclude_unmodeled_services!`](@ref)
does; the forecasts are attached only by the first call. The per-step inputs of the replay are fixed by the
first call; a later change to the observed state is not read.

# Arguments
- `sys`: the replay system, mutated in place: its availability changes and forecasts are attached on the first call.
- `template`: the `PSI.ProblemTemplate` the replay builds, e.g. [`template_nemde`](@ref)().
- `steps`: a non-empty range of five-minute interval-ending timestamps covered by the inputs of `sys`.
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
    _prepare_replay_forecasts!(sys)
    check_replication_steps(sys, steps)
    check_single_financial_year(steps)
    exclude = _has_service_model(template, GenericConstraint) ?
        merge(never_invoked_constraints(sys, steps), exclude_constraints) : Dict{String, Symbol}(exclude_constraints)
    skipped = DataFrame(exclude_unmodeled_services!(sys, template; exclude_constraints = exclude))
    check_dispatch_envelope(template, sys, first(steps), length(steps))
    return skipped
end
