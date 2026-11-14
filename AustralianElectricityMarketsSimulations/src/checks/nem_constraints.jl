# Buildability of `GenericConstraint`s against a `PSI.ProblemTemplate`, and the skipped-constraints report.

# Term failures, each a reason and, for `:unmodeled_device_type`, the device type.
const _TermFailures = Vector{Tuple{Symbol, Union{Nothing, DataType}}}


function _modeled_device_types(template::PSI.ProblemTemplate)
    models = Iterators.flatten((values(PSI.get_device_models(template)), values(PSI.get_branch_models(template))))
    return DataType[PSI.get_component_type(m) for m in models]
end


# Names of the available FCASServices the template models under FCASMarket: a named model's service,
# and every available service of a type-level model, which PSI expands over the available services.
function _modeled_fcas_services(template::PSI.ProblemTemplate, sys::PSY.System)
    names = Set{String}()
    for ((name, _), model) in PSI.get_service_models(template)
        PSI.get_component_type(model) == FCASService && PSI.get_formulation(model) == FCASMarket || continue
        if isempty(name)
            union!(names, PSY.get_name(svc) for svc in PSY.get_components(PSY.get_available, FCASService, sys))
        else
            push!(names, name)
        end
    end
    return names
end


# An FCAS term needs its device's service modelled; an absent, unavailable or deviceless service
# contributes zero at build, so it is not a failure.
function _fcas_failures(
        sys::PSY.System, device::PSY.Device, bid_type::BidType, fcas_modeled::Set{String}, modeled_types::Vector{DataType},
    )
    name = fcas_service_name(device, bid_type)
    svc = bid_type == BidType.ENERGY ? nothing : PSY.get_component(FCASService, sys, name)
    (isnothing(svc) || !PSY.get_available(svc) || name in fcas_modeled) && return _TermFailures()
    devices = filter(PSY.get_available, PSY.get_contributing_devices(sys, svc))
    isempty(devices) && return _TermFailures()
    if !any(d -> _type_modeled(d, modeled_types), devices)
        return _TermFailures([(:unmodeled_device_type, typeof(d)) for d in devices])
    end
    return _TermFailures([(:unmodeled_fcas_service, nothing)])
end


function _interconnector_modeled(template::PSI.ProblemTemplate)
    return any(m -> PSI.get_component_type(m) == PSY.AreaInterchange, values(PSI.get_branch_models(template)))
end


function _type_modeled(device::PSY.Device, modeled_types::Vector{DataType})
    return any(t -> device isa t, modeled_types)
end


function _term_failures(
        sys::PSY.System, term::UnitTerm, modeled_types::Vector{DataType}, ::Bool, fcas_modeled::Set{String},
    )
    device = PSY.get_component(PSY.Device, sys, get_duid(term))
    isnothing(device) &&
        return _TermFailures([(:missing_component, nothing)])
    _type_modeled(device, modeled_types) ||
        return _TermFailures([(:unmodeled_device_type, typeof(device))])
    return _fcas_failures(sys, device, get_bid_type(term), fcas_modeled, modeled_types)
end


function _term_failures(
        sys::PSY.System, term::RegionTerm, modeled_types::Vector{DataType}, ::Bool, fcas_modeled::Set{String},
    )
    failures = _TermFailures()
    for dname in get_devices(term)
        device = PSY.get_component(PSY.Device, sys, dname)
        if isnothing(device)
            push!(failures, (:missing_component, nothing))
        elseif !_type_modeled(device, modeled_types)
            push!(failures, (:unmodeled_device_type, typeof(device)))
        else
            append!(failures, _fcas_failures(sys, device, get_bid_type(term), fcas_modeled, modeled_types))
        end
    end
    return failures
end


function _term_failures(
        sys::PSY.System, term::InterconnectorTerm, ::Vector{DataType}, interconnector_modeled::Bool, ::Set{String},
    )
    device = PSY.get_component(PSY.AreaInterchange, sys, get_interconnector(term))
    isnothing(device) &&
        return _TermFailures([(:missing_component, nothing)])
    interconnector_modeled && return _TermFailures()
    return _TermFailures([(:unmodeled_device_type, PSY.AreaInterchange)])
end


"""
    _constraint_diagnosis(sys, gc, modeled_types, interconnector_modeled, fcas_modeled; tolerated_reasons = Set{Symbol}(), tolerated_types = DataType[]) -> Union{Nothing, Tuple{Symbol, Vector{DataType}, Int, Bool}}

The first failure that is not tolerated, or the first failure when all are tolerated, with its
device types, failure count and whether it is blocking. A failure is tolerated when its reason is
in `tolerated_reasons`, or, for `:unmodeled_device_type`, when its device type is a subtype of one
of `tolerated_types`. Returns `nothing` when every term is buildable.
"""
function _constraint_diagnosis(
        sys::PSY.System, gc::GenericConstraint, modeled_types::Vector{DataType},
        interconnector_modeled::Bool, fcas_modeled::Set{String};
        tolerated_reasons = Set{Symbol}(), tolerated_types = DataType[],
    )
    failures = _TermFailures()
    for term in get_terms(gc)
        append!(failures, _term_failures(sys, term, modeled_types, interconnector_modeled, fcas_modeled))
    end
    isempty(failures) && return nothing
    tolerated(f) = f[1] == :unmodeled_device_type ?
        (!isnothing(f[2]) && any(t -> f[2] <: t, tolerated_types)) : f[1] in tolerated_reasons
    blocking = findfirst(!tolerated, failures)
    reason = failures[something(blocking, 1)][1]
    types = unique(DataType[t for (r, t) in failures if r == reason && !isnothing(t)])
    return (reason, types, count(f -> f[1] == reason, failures), !isnothing(blocking))
end


# Unbuildable reasons that a template without an FCAS service model causes.
function _left_out_reasons(template::PSI.ProblemTemplate)
    _has_service_model(template, FCASService) && return Set{Symbol}()
    return Set([:unmodeled_fcas_service])
end


# Device types whose terms a template without their device model leaves unmodeled.
function _left_out_types(template::PSI.ProblemTemplate)
    _has_device_model(template, PSY.AreaInterchange) && return DataType[]
    return DataType[PSY.AreaInterchange]
end


# The constraints the template's `"excluded_constraints"` attribute names, with their reasons. The
# attribute is on the aggregated model and on each per-name model PSI expands it into.
function _excluded_constraints(template::PSI.ProblemTemplate)
    excluded = Dict{String, Symbol}()
    for model in values(PSI.get_service_models(template))
        PSI.get_component_type(model) == GenericConstraint || continue
        merge!(excluded, something(PSI.get_attribute(model, "excluded_constraints"), Dict{String, Symbol}()))
    end
    return excluded
end


const _ConstraintRow = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int}


# One row per constraint of `constraints` that `template` cannot build, sorted by name, with whether
# the failure is blocking: not left out by the template's own scope.
function _diagnose_constraints(sys::PSY.System, template::PSI.ProblemTemplate, constraints)
    modeled_types = _modeled_device_types(template)
    interconnector_modeled = _interconnector_modeled(template)
    fcas_modeled = _modeled_fcas_services(template, sys)
    tolerated_reasons = _left_out_reasons(template)
    tolerated_types = _left_out_types(template)
    rows = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int, blocking::Bool}[]
    for gc in sort(collect(constraints); by = PSY.get_name)
        diagnosis = _constraint_diagnosis(
            sys, gc, modeled_types, interconnector_modeled, fcas_modeled; tolerated_reasons, tolerated_types,
        )
        isnothing(diagnosis) && continue
        reason, _, n_failed, blocking = diagnosis
        push!(rows, (constraint = PSY.get_name(gc), reason = reason, n_missing = n_failed, blocking = blocking))
    end
    return rows
end


# The rows of the available constraints the template leaves out: those it excludes by name (`n_missing = 0`)
# and those it cannot build, sorted by name. Empty without a `GenericConstraint` service model.
function _template_fact_rows(sys::PSY.System, template::PSI.ProblemTemplate)
    rows = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int, blocking::Bool}[]
    _has_service_model(template, GenericConstraint) || return rows
    excluded = _excluded_constraints(template)
    candidates = GenericConstraint[]
    for gc in PSY.get_components(PSY.get_available, GenericConstraint, sys)
        name = PSY.get_name(gc)
        if haskey(excluded, name)
            push!(rows, (constraint = name, reason = excluded[name], n_missing = 0, blocking = false))
        else
            push!(candidates, gc)
        end
    end
    append!(rows, _diagnose_constraints(sys, template, candidates))
    sort!(rows; by = r -> r.constraint)
    return rows
end


"""
    _blocked_constraints(sys, template; facts = _template_fact_rows(sys, template)) -> Vector{@NamedTuple{constraint::String, reason::Symbol}}

The available constraints of `sys` that `template` cannot build for a reason it does not tolerate: a missing
component, an unmodeled device type other than the interchanger of a template without interchangers,
or an FCAS service left unmodeled while the template models FCAS.
"""
function _blocked_constraints(sys::PSY.System, template::PSI.ProblemTemplate; facts = _template_fact_rows(sys, template))
    return @NamedTuple{constraint::String, reason::Symbol}[(constraint = r.constraint, reason = r.reason) for r in facts if r.blocking]
end


"""
    replay_skipped_constraints(sys, template) -> DataFrame

The `GenericConstraint`s of `sys` that a replay of `template` leaves out, without changing `sys` or
`template`. The rows are the constraints unavailable from the build ([`get_unavailable_constraints`](@ref), with
`n_missing = 0`), the available constraints the template excludes by name, with `n_missing = 0`, and
every other available constraint the template cannot build, with the number of failing terms.
A template with no `GenericConstraint` service model reports the unavailable constraints only. It reads the
caller's template or the expanded template of a built model alike.

# Arguments
- `sys`: the replay system built by [`nem_system`](@ref).
- `template`: the `PSI.ProblemTemplate` the replay builds, e.g. [`template_nemde`](@ref)().

# Returns
A `DataFrame` with columns `constraint`, `reason` and `n_missing`, sorted by constraint name.
"""
function replay_skipped_constraints(sys::PSY.System, template::PSI.ProblemTemplate)
    rows = _ConstraintRow[
        (constraint = r.constraint, reason = r.reason, n_missing = 0) for r in eachrow(get_unavailable_constraints(sys))
    ]
    append!(rows, _ConstraintRow[(constraint = r.constraint, reason = r.reason, n_missing = r.n_missing) for r in _template_fact_rows(sys, template)])
    sort!(rows; by = r -> r.constraint)
    return DataFrame(rows)
end
