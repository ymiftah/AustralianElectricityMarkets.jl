"""
The optional families of [`template_nemde`](@ref) that its `parts` argument selects:
`:batteries` (`PSY.Storage` devices under [`AbstractNEMDispatch`](@ref)), `:fcas` (an
[`FCASMarket`](@ref) per `FCASService`), `:losses` ([`NEMInterconnectorLoss`](@ref) on each
`PSY.AreaInterchange`), `:tie_breaks` (the [`TieBreakMarket`](@ref) service model) and
`:generic_constraints` (a [`LinearFactorLimit`](@ref) per `GenericConstraint`).
"""
const REPLICATION_PARTS = (:batteries, :fcas, :losses, :tie_breaks, :generic_constraints)


"""
    template_nemde(parts = REPLICATION_PARTS) -> PSI.ProblemTemplate

Builds the data-free `PSI.ProblemTemplate` that replicates NEMDE: [`NEMReplayDispatch`](@ref) for the
types of [`NEM_DISPATCH_DEVICE_TYPES`](@ref), `PSI.StaticPowerLoad` demand, and `PSI.AreaBalancePowerModel`
regions. The network model's balance slacks carry PSI's default slack cost here; only
[`replication_decision_model`](@ref) prices them at the Market Price Cap. The formulations of the `parts`
families are type-level: [`exclude_unmodeled_services!`](@ref) then sets the components the replay leaves
out unavailable, and PSI expands each type-level service model over the available components when it builds.

# Arguments
- `parts`: the [`REPLICATION_PARTS`](@ref) to model; default all.

# Returns
A `PSI.ProblemTemplate`. Throws `ArgumentError` on an unknown part.
"""
function template_nemde(parts = REPLICATION_PARTS)
    check_replication_parts(parts)
    template = PSI.ProblemTemplate(
        PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true, duals = [PSI.CopperPlateBalanceConstraint]),
    )
    for T in NEM_DISPATCH_DEVICE_TYPES
        T <: PSY.Storage && !(:batteries in parts) && continue
        PSI.set_device_model!(template, T, NEMReplayDispatch)
    end
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    :losses in parts && PSI.set_device_model!(template, PSY.AreaInterchange, NEMInterconnectorLoss)
    :fcas in parts && PSI.set_service_model!(
        template,
        PSI.ServiceModel(FCASService, FCASMarket; duals = [FCASJointCapacityConstraint], use_slacks = true),
    )
    :generic_constraints in parts && PSI.set_service_model!(
        template,
        PSI.ServiceModel(GenericConstraint, LinearFactorLimit; duals = [NEMConstraintLimit], use_slacks = true),
    )
    :tie_breaks in parts && PSI.set_service_model!(template, PSI.ServiceModel(EnergyTieBreak, TieBreakMarket))
    return template
end


"""
    check_replication_parts(parts) -> Nothing

Throws `ArgumentError` naming the entries of `parts` that are not in [`REPLICATION_PARTS`](@ref).

# Arguments
- `parts`: the replay families to model.

# Returns
`nothing`.
"""
function check_replication_parts(parts)
    unknown = setdiff(parts, REPLICATION_PARTS)
    isempty(unknown) || throw(
        ArgumentError("template_nemde: unknown parts $(Tuple(unknown)); choose from $REPLICATION_PARTS."),
    )
    return
end


# Ext key of the components the last `exclude_unmodeled_services!` call on a system set unavailable,
# as a `Dict` from each excluded type's name to the names it disabled.
const _REPLAY_EXCLUSIONS_KEY = "replay_excluded_services"


"""
    exclude_unmodeled_services!(sys, template; parts = REPLICATION_PARTS, exclude_constraints = Dict{String, Symbol}()) -> Vector{@NamedTuple{constraint::String, reason::Symbol, n_missing::Int}}

Sets unavailable the components of `sys` that the replay of `parts` cannot model under `template`, and
returns one `(constraint, reason, n_missing)` record per `GenericConstraint` left out. Storage-only FCAS
services are excluded only when `:fcas` is in `parts` and `:batteries` is not: an `FCASService` whose
available contributors are all `PSY.Storage` is set unavailable and not recorded. With `:generic_constraints`,
each `GenericConstraint` named in `exclude_constraints` is set unavailable with its given reason and
`n_missing = 0`, and each other available constraint that the template cannot build is set unavailable
with the reason and count of its failing terms. A constraint whose contributing devices are all
unavailable is recorded as `:no_available_device`.

Each call replaces the exclusions of the previous call on the same system: it first sets available again
exactly the components that call disabled, then computes its own exclusions. Components it did not
disable, such as those unavailable in the input, are left as they are. Nothing is changed when it throws.

# Arguments
- `sys`: the replay system, mutated in place.
- `template`: a [`template_nemde`](@ref) built with the same `parts`.
- `parts`: the [`REPLICATION_PARTS`](@ref) the replay models.
- `exclude_constraints`: a `Dict` from the names of `GenericConstraint`s of `sys` to the `reason` each is
  recorded with; default empty.

# Returns
The records, sorted by constraint name. Throws `ArgumentError` for an unknown part, an unknown excluded
constraint, or a constraint the template cannot model for a reason other than a left-out part.
"""
function exclude_unmodeled_services!(
        sys::PSY.System, template::PSI.ProblemTemplate; parts = REPLICATION_PARTS,
        exclude_constraints::AbstractDict{<:AbstractString, Symbol} = Dict{String, Symbol}(),
    )
    check_replication_parts(parts)
    previous = pop!(PSY.get_ext(sys), _REPLAY_EXCLUSIONS_KEY, nothing)
    isnothing(previous) || _set_replay_availability!(sys, previous, true)
    rows = try
        _exclude_unmodeled_services!(sys, template, parts, exclude_constraints)
    catch
        if !isnothing(previous)
            _set_replay_availability!(sys, previous, false)
            PSY.get_ext(sys)[_REPLAY_EXCLUSIONS_KEY] = previous
        end
        rethrow()
    end
    return rows
end


# Sets the components named in `excluded` (keyed by the name of their type) to `available`.
function _set_replay_availability!(sys::PSY.System, excluded::AbstractDict, available::Bool)
    for T in (FCASService, GenericConstraint)
        for name in get(excluded, string(nameof(T)), String[])
            PSY.set_available!(PSY.get_component(T, sys, name), available)
        end
    end
    return
end


function _exclude_unmodeled_services!(
        sys::PSY.System, template::PSI.ProblemTemplate, parts, exclude_constraints::AbstractDict{<:AbstractString, Symbol},
    )
    rows = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int}[]
    storage_fcas = :fcas in parts && !(:batteries in parts) ? _storage_only_fcas_services(sys) : String[]
    unavailable_constraints = String[]
    if :generic_constraints in parts
        unknown = sort!([n for n in keys(exclude_constraints) if isnothing(PSY.get_component(GenericConstraint, sys, n))])
        isempty(unknown) || throw(
            ArgumentError(
                "exclude_unmodeled_services!: exclude_constraints names $(join(unknown, ", ")), " *
                    "which are not GenericConstraints of sys.",
            ),
        )
        candidates = GenericConstraint[]
        for gc in PSY.get_components(PSY.get_available, GenericConstraint, sys)
            name = PSY.get_name(gc)
            if haskey(exclude_constraints, name)
                push!(rows, (constraint = name, reason = exclude_constraints[name], n_missing = 0))
                push!(unavailable_constraints, name)
            else
                push!(candidates, gc)
            end
        end
        tolerated = _left_out_part_reasons(parts)
        tolerated_types = _left_out_part_types(parts)
        blocked = @NamedTuple{constraint::String, reason::Symbol}[]
        buildable = _filter_buildable_generic_constraints(
            sys, template, candidates; allow_partial_coverage = !isempty(tolerated) || !isempty(tolerated_types),
            skipped = rows, tolerated_reasons = tolerated, tolerated_types = tolerated_types, blocked = blocked,
            unmodeled_fcas = storage_fcas,
        )
        isempty(blocked) || throw(
            ArgumentError(
                "exclude_unmodeled_services!: generic constraints the template cannot model: " *
                    "$(join(("$(r.constraint) ($(r.reason))" for r in blocked), ", ")).",
            ),
        )
        kept = Set(PSY.get_name(gc) for gc in buildable)
        append!(unavailable_constraints, (PSY.get_name(gc) for gc in candidates if !(PSY.get_name(gc) in kept)))
    end
    for name in storage_fcas
        PSY.set_available!(PSY.get_component(FCASService, sys, name), false)
    end
    for name in unavailable_constraints
        PSY.set_available!(PSY.get_component(GenericConstraint, sys, name), false)
    end
    PSY.get_ext(sys)[_REPLAY_EXCLUSIONS_KEY] = Dict("FCASService" => storage_fcas, "GenericConstraint" => unavailable_constraints)
    sort!(rows; by = r -> r.constraint)
    return rows
end


# Names of the FCASServices, available or already excluded, whose available contributors are all storage.
function _storage_only_fcas_services(sys::PSY.System)
    names = String[]
    for svc in PSY.get_components(FCASService, sys)
        devices = filter(PSY.get_available, PSY.get_contributing_devices(sys, svc))
        !isempty(devices) && all(d -> d isa PSY.Storage, devices) && push!(names, PSY.get_name(svc))
    end
    return names
end


# Unbuildable reasons a left-out part causes: FCAS terms without `:fcas`.
function _left_out_part_reasons(parts)
    reasons = Set{Symbol}()
    :fcas in parts || push!(reasons, :unmodeled_fcas_service)
    return reasons
end


# Device types whose terms a left-out part makes unmodeled: storage without `:batteries`, interchange without `:losses`.
function _left_out_part_types(parts)
    types = DataType[]
    :batteries in parts || push!(types, PSY.Storage)
    :losses in parts || push!(types, PSY.AreaInterchange)
    return types
end
