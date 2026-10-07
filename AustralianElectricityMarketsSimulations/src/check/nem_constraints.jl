# Pre-flight buildability check for `GenericConstraint`s against a `PSI.ProblemTemplate`,
# reusing the reason vocabulary `nem_constraints.jl`'s `_checked_device`/`_checked_devices`/
# `_checked_interconnector` throw with, but reading only already-resolved data.

const _UNBUILDABLE_REASONS = (:unmodeled_fcas_service, :missing_component, :unmodeled_device_type)

const _REASON_LABELS = Dict(
    :unmodeled_fcas_service => "FCAS term whose service has contributing devices but no FCASMarket model in the template",
    :missing_component => "missing component (named device not found in the System)",
    :unmodeled_device_type => "unmodeled device type (template does not model these device types)",
)

_modeled_device_types(template::PSI.ProblemTemplate) = DataType[
    PSI.get_component_type(m) for
        m in Iterators.flatten((values(PSI.get_device_models(template)), values(PSI.get_branch_models(template))))
]

# Names of the FCASServices the template models under FCASMarket, as `check_fcas_services` reads them.
_modeled_fcas_services(template::PSI.ProblemTemplate) = Set(
    name for ((name, _), model) in PSI.get_service_models(template)
        if PSI.get_component_type(model) == FCASService && PSI.get_formulation(model) == FCASMarket
)

# An FCAS term needs its device's service modelled; an absent, unavailable or deviceless service
# contributes zero at build, so it is not a failure.
function _fcas_failures(sys::PSY.System, device::PSY.Device, bid_type::BidType, fcas_modeled::Set{String})
    name = fcas_service_name(device, bid_type)
    svc = bid_type == BidType.ENERGY ? nothing : PSY.get_component(FCASService, sys, name)
    (isnothing(svc) || !PSY.get_available(svc) || name in fcas_modeled) &&
        return Tuple{Symbol, Union{Nothing, DataType}}[]
    any(PSY.get_available, PSY.get_contributing_devices(sys, svc)) ||
        return Tuple{Symbol, Union{Nothing, DataType}}[]
    return Tuple{Symbol, Union{Nothing, DataType}}[(:unmodeled_fcas_service, nothing)]
end

_interconnector_modeled(template::PSI.ProblemTemplate) = any(
    m -> PSI.get_component_type(m) == PSY.AreaInterchange, values(PSI.get_branch_models(template)),
)

_type_modeled(device::PSY.Device, modeled_types::Vector{DataType}) =
    any(t -> device isa t, modeled_types)

function _term_failures(
        sys::PSY.System, term::UnitTerm, modeled_types::Vector{DataType}, ::Bool, fcas_modeled::Set{String},
    )
    device = PSY.get_component(PSY.Device, sys, get_duid(term))
    isnothing(device) &&
        return Tuple{Symbol, Union{Nothing, DataType}}[(:missing_component, nothing)]
    _type_modeled(device, modeled_types) ||
        return Tuple{Symbol, Union{Nothing, DataType}}[(:unmodeled_device_type, typeof(device))]
    return _fcas_failures(sys, device, get_bid_type(term), fcas_modeled)
end

function _term_failures(
        sys::PSY.System, term::RegionTerm, modeled_types::Vector{DataType}, ::Bool, fcas_modeled::Set{String},
    )
    failures = Tuple{Symbol, Union{Nothing, DataType}}[]
    for dname in get_devices(term)
        device = PSY.get_component(PSY.Device, sys, dname)
        if isnothing(device)
            push!(failures, (:missing_component, nothing))
        elseif !_type_modeled(device, modeled_types)
            push!(failures, (:unmodeled_device_type, typeof(device)))
        else
            append!(failures, _fcas_failures(sys, device, get_bid_type(term), fcas_modeled))
        end
    end
    return failures
end

function _term_failures(
        sys::PSY.System, term::InterconnectorTerm, ::Vector{DataType}, interconnector_modeled::Bool,
        ::Set{String},
    )
    device = PSY.get_component(PSY.AreaInterchange, sys, get_interconnector(term))
    isnothing(device) &&
        return Tuple{Symbol, Union{Nothing, DataType}}[(:missing_component, nothing)]
    interconnector_modeled && return Tuple{Symbol, Union{Nothing, DataType}}[]
    return Tuple{Symbol, Union{Nothing, DataType}}[(:unmodeled_device_type, PSY.AreaInterchange)]
end

"""
    _constraint_diagnosis(sys, gc, modeled_types, interconnector_modeled, fcas_modeled) -> Union{Nothing, Tuple{Symbol, Vector{DataType}}}

The first unbuildable reason found across `gc`'s terms, and every device type responsible for
that reason, or `nothing` if every term is buildable.
"""
function _constraint_diagnosis(
        sys::PSY.System, gc::GenericConstraint, modeled_types::Vector{DataType},
        interconnector_modeled::Bool, fcas_modeled::Set{String},
    )
    failures = Tuple{Symbol, Union{Nothing, DataType}}[]
    for term in get_terms(gc)
        append!(failures, _term_failures(sys, term, modeled_types, interconnector_modeled, fcas_modeled))
    end
    isempty(failures) && return nothing
    reason = first(failures)[1]
    types = unique(DataType[t for (r, t) in failures if r == reason && !isnothing(t)])
    return (reason, types)
end

"A `name => types` line for the aggregated message/warning, capped to the first 20 per reason."
function _reason_block(reason::Symbol, entries::Vector{Tuple{String, Vector{DataType}}})
    lines = ["  $(_REASON_LABELS[reason]) ($(length(entries))):"]
    for (name, types) in first(entries, 20)
        suffix = isempty(types) ? "" : " ($(join(string.(types), ", ")))"
        push!(lines, "    - $name$suffix")
    end
    length(entries) > 20 && push!(lines, "    … and $(length(entries) - 20) more")
    return join(lines, "\n")
end

function _aggregated_message(grouped::Dict{Symbol, Vector{Tuple{String, Vector{DataType}}}})
    n_total = sum(length(v) for v in values(grouped))
    blocks = [_reason_block(r, grouped[r]) for r in _UNBUILDABLE_REASONS if haskey(grouped, r)]
    return "template cannot build $n_total GenericConstraint(s):\n" * join(blocks, "\n") *
        "\nPass allow_partial_coverage = true to proceed with the buildable subset."
end

"""
    filter_buildable_generic_constraints(sys, template; allow_partial_coverage = false, skipped = nothing) -> Vector{GenericConstraint}

The [`GenericConstraint`](@ref)s in `sys` that `template` can build under
[`LinearFactorLimit`](@ref). A constraint is unbuildable when a `UnitTerm`/`RegionTerm` has a
FCAS term's service (see [`fcas_service_name`](@ref)) exists with available devices but has no
[`FCASMarket`](@ref) model in `template`, a term's named component is missing from `sys`, or a
device's type isn't modelled by any `DeviceModel`/branch model in `template` (an
`InterconnectorTerm` needs `PSY.AreaInterchange` modelled as a branch). Constraints with `PSY.get_available(gc) == false`
are skipped entirely. A constraint whose contributing devices are all unavailable is left out
without being a failure.

# Arguments
- `sys`: system to read constraints and components from.
- `template`: `PSI.ProblemTemplate` to check device and branch coverage against.
- `allow_partial_coverage`: when `false` (default), throws a single aggregated `ArgumentError`
  naming every unbuildable constraint and its reason if any exist. When `true`, returns the
  buildable subset and emits one summary `@warn` with counts by reason.
- `skipped`: a vector to which one `(constraint, reason, n_missing)` named tuple is appended per
  constraint left out because all its contributing devices are unavailable (`reason =
  :no_available_device`), or `nothing`.

# Returns
A `Vector{GenericConstraint}`, sorted by name.
"""
function filter_buildable_generic_constraints(
        sys::PSY.System, template::PSI.ProblemTemplate; allow_partial_coverage::Bool = false,
        skipped::Union{Nothing, AbstractVector} = nothing,
    )
    modeled_types = _modeled_device_types(template)
    interconnector_modeled = _interconnector_modeled(template)
    fcas_modeled = _modeled_fcas_services(template)

    gcs = sort(collect(PSY.get_components(GenericConstraint, sys)); by = PSY.get_name)
    buildable = GenericConstraint[]
    grouped = Dict{Symbol, Vector{Tuple{String, Vector{DataType}}}}()
    for gc in gcs
        PSY.get_available(gc) || continue
        # PSI cannot build a service whose contributing devices are all unavailable; such a
        # constraint has no variable to bind, so it is left out rather than reported as a failure.
        devices = PSY.get_contributing_devices(sys, gc)
        if !isempty(devices) && !any(PSY.get_available, devices)
            isnothing(skipped) || push!(skipped, (constraint = PSY.get_name(gc), reason = :no_available_device, n_missing = 0))
            continue
        end
        diagnosis = _constraint_diagnosis(sys, gc, modeled_types, interconnector_modeled, fcas_modeled)
        if isnothing(diagnosis)
            push!(buildable, gc)
        else
            reason, types = diagnosis
            push!(get!(grouped, reason, Tuple{String, Vector{DataType}}[]), (PSY.get_name(gc), types))
        end
    end

    isempty(grouped) && return buildable

    if allow_partial_coverage
        counts = join(("$(length(v)) $(_REASON_LABELS[r])" for (r, v) in grouped), "; ")
        n_total = sum(length(v) for v in values(grouped))
        @warn "Skipping $n_total unbuildable GenericConstraint(s): $counts"
        return buildable
    end

    throw(ArgumentError(_aggregated_message(grouped)))
end
