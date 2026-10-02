# Pre-flight buildability check for `GenericConstraint`s against a `PSI.ProblemTemplate`,
# reusing the reason vocabulary `nem_constraints.jl`'s `_checked_device`/`_checked_devices`/
# `_checked_interconnector` throw with, but reading only already-resolved data.

const _UNBUILDABLE_REASONS = (:unsupported_bid_type, :missing_component, :unmodeled_device_type)

const _REASON_LABELS = Dict(
    :unsupported_bid_type => "unsupported bid_type (LinearFactorLimit only builds ENERGY terms)",
    :missing_component => "missing component (named device not found in the System)",
    :unmodeled_device_type => "unmodeled device type (template does not model these device types)",
)

_modeled_device_types(template::PSI.ProblemTemplate) = DataType[
    PSI.get_component_type(m) for
        m in Iterators.flatten((values(PSI.get_device_models(template)), values(PSI.get_branch_models(template))))
]

_interconnector_modeled(template::PSI.ProblemTemplate) = any(
    m -> PSI.get_component_type(m) == PSY.AreaInterchange, values(PSI.get_branch_models(template)),
)

_type_modeled(device::PSY.Device, modeled_types::Vector{DataType}) =
    any(t -> device isa t, modeled_types)

function _term_failures(sys::PSY.System, term::UnitTerm, modeled_types::Vector{DataType}, ::Bool)
    get_bid_type(term) == BidType.ENERGY ||
        return Tuple{Symbol, Union{Nothing, DataType}}[(:unsupported_bid_type, nothing)]
    device = PSY.get_component(PSY.Device, sys, get_duid(term))
    isnothing(device) &&
        return Tuple{Symbol, Union{Nothing, DataType}}[(:missing_component, nothing)]
    _type_modeled(device, modeled_types) && return Tuple{Symbol, Union{Nothing, DataType}}[]
    return Tuple{Symbol, Union{Nothing, DataType}}[(:unmodeled_device_type, typeof(device))]
end

function _term_failures(sys::PSY.System, term::RegionTerm, modeled_types::Vector{DataType}, ::Bool)
    get_bid_type(term) == BidType.ENERGY ||
        return Tuple{Symbol, Union{Nothing, DataType}}[(:unsupported_bid_type, nothing)]
    failures = Tuple{Symbol, Union{Nothing, DataType}}[]
    for dname in get_devices(term)
        device = PSY.get_component(PSY.Device, sys, dname)
        if isnothing(device)
            push!(failures, (:missing_component, nothing))
        elseif !_type_modeled(device, modeled_types)
            push!(failures, (:unmodeled_device_type, typeof(device)))
        end
    end
    return failures
end

function _term_failures(
        sys::PSY.System, term::InterconnectorTerm, ::Vector{DataType}, interconnector_modeled::Bool,
    )
    device = PSY.get_component(PSY.AreaInterchange, sys, get_interconnector(term))
    isnothing(device) &&
        return Tuple{Symbol, Union{Nothing, DataType}}[(:missing_component, nothing)]
    interconnector_modeled && return Tuple{Symbol, Union{Nothing, DataType}}[]
    return Tuple{Symbol, Union{Nothing, DataType}}[(:unmodeled_device_type, PSY.AreaInterchange)]
end

"""
    _constraint_diagnosis(sys, gc, modeled_types, interconnector_modeled) -> Union{Nothing, Tuple{Symbol, Vector{DataType}}}

The first unbuildable reason found across `gc`'s terms, and every device type responsible for
that reason, or `nothing` if every term is buildable.
"""
function _constraint_diagnosis(
        sys::PSY.System, gc::GenericConstraint, modeled_types::Vector{DataType},
        interconnector_modeled::Bool,
    )
    failures = Tuple{Symbol, Union{Nothing, DataType}}[]
    for term in get_terms(gc)
        append!(failures, _term_failures(sys, term, modeled_types, interconnector_modeled))
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
    filter_buildable_generic_constraints(sys, template; allow_partial_coverage = false) -> Vector{GenericConstraint}

The [`GenericConstraint`](@ref)s in `sys` that `template` can build under
[`LinearFactorLimit`](@ref). A constraint is unbuildable when a `UnitTerm`/`RegionTerm` has a
non-`ENERGY` `bid_type`, a term's named component is missing from `sys`, or a device's type
isn't modelled by any `DeviceModel`/branch model in `template` (an `InterconnectorTerm` needs
`PSY.AreaInterchange` modelled as a branch). Constraints with `PSY.get_available(gc) == false`
are skipped entirely.

# Arguments
- `sys`: system to read constraints and components from.
- `template`: `PSI.ProblemTemplate` to check device and branch coverage against.
- `allow_partial_coverage`: when `false` (default), throws a single aggregated `ArgumentError`
  naming every unbuildable constraint and its reason if any exist. When `true`, returns the
  buildable subset and emits one summary `@warn` with counts by reason.

# Returns
A `Vector{GenericConstraint}`, sorted by name.
"""
function filter_buildable_generic_constraints(
        sys::PSY.System, template::PSI.ProblemTemplate; allow_partial_coverage::Bool = false,
    )
    modeled_types = _modeled_device_types(template)
    interconnector_modeled = _interconnector_modeled(template)

    gcs = sort(collect(PSY.get_components(GenericConstraint, sys)); by = PSY.get_name)
    buildable = GenericConstraint[]
    grouped = Dict{Symbol, Vector{Tuple{String, Vector{DataType}}}}()
    for gc in gcs
        PSY.get_available(gc) || continue
        diagnosis = _constraint_diagnosis(sys, gc, modeled_types, interconnector_modeled)
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
