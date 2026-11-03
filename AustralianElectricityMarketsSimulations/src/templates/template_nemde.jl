"""
    template_nemde() -> PSI.ProblemTemplate

Builds the `PSI.ProblemTemplate` that replicates NEMDE. It models [`NEMReplayDispatch`](@ref) for each
type of [`NEM_DISPATCH_DEVICE_TYPES`](@ref), including the batteries, `PSI.StaticPowerLoad` demand,
[`NEMInterconnectorLoss`](@ref) on each `PSY.AreaInterchange`, an [`FCASMarket`](@ref) per `FCASService`,
a [`LinearFactorLimit`](@ref) per `GenericConstraint` and the [`TieBreakMarket`](@ref) service model, over
`PSI.AreaBalancePowerModel` regions. The balance slacks carry PSI's default slack cost here; only
[`replication_decision_model`](@ref) prices them at the Market Price Cap.

A replay that models less builds its own `PSI.ProblemTemplate` and passes it in.
[`exclude_unmodeled_services!`](@ref), [`check_template_against_sys`](@ref) and
[`check_fcas_services`](@ref) read what is modeled from the template they are given.

# Returns
A `PSI.ProblemTemplate`.
"""
function template_nemde()
    template = PSI.ProblemTemplate(
        PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true, duals = [PSI.CopperPlateBalanceConstraint]),
    )
    PSI.set_device_model!(template, PSY.ThermalStandard, NEMReplayDispatch)
    PSI.set_device_model!(template, PSY.HydroDispatch, NEMReplayDispatch)
    PSI.set_device_model!(template, PSY.RenewableDispatch, NEMReplayDispatch)
    PSI.set_device_model!(template, PSY.InterruptiblePowerLoad, NEMReplayDispatch)
    PSI.set_device_model!(template, PSY.EnergyReservoirStorage, NEMReplayDispatch)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_device_model!(template, PSY.AreaInterchange, NEMInterconnectorLoss)
    PSI.set_service_model!(
        template,
        PSI.ServiceModel(FCASService, FCASMarket; duals = [FCASJointCapacityConstraint], use_slacks = true),
    )
    PSI.set_service_model!(
        template,
        PSI.ServiceModel(GenericConstraint, LinearFactorLimit; duals = [NEMConstraintLimit], use_slacks = true),
    )
    PSI.set_service_model!(template, PSI.ServiceModel(EnergyTieBreak, TieBreakMarket))
    return template
end


"""
    _has_device_model(template, ::Type{T}) -> Bool

Whether `template` models a device or branch whose component type is a subtype of `T`.

# Returns
`Bool`.
"""
function _has_device_model(template::PSI.ProblemTemplate, ::Type{T}) where {T}
    models = Iterators.flatten((values(PSI.get_device_models(template)), values(PSI.get_branch_models(template))))
    return any(m -> PSI.get_component_type(m) <: T, models)
end


"""
    _has_service_model(template, ::Type{T}) -> Bool

Whether `template` models a service whose component type is a subtype of `T`.

# Returns
`Bool`.
"""
function _has_service_model(template::PSI.ProblemTemplate, ::Type{T}) where {T}
    return any(m -> PSI.get_component_type(m) <: T, values(PSI.get_service_models(template)))
end


# Ext key of the components the last `exclude_unmodeled_services!` call on a system set unavailable,
# as a `Dict` from each excluded type's name to the names it disabled.
const _REPLAY_EXCLUSIONS_KEY = "replay_excluded_services"


"""
    exclude_unmodeled_services!(sys, template; exclude_constraints = Dict{String, Symbol}()) -> Vector{@NamedTuple{constraint::String, reason::Symbol, n_missing::Int}}

Sets unavailable the components of `sys` that `template` cannot model, and returns one
`(constraint, reason, n_missing)` record per `GenericConstraint` left out. When `template` has a
`GenericConstraint` service model, each `GenericConstraint` named in `exclude_constraints` is set
unavailable with its given reason and `n_missing = 0`, and each other available constraint that the
template cannot build is set unavailable with the reason and count of its failing terms. A constraint
whose contributing devices are all unavailable is recorded as `:no_available_device`. Failures caused
by a missing FCAS service model or a missing `PSY.AreaInterchange` model are excluded and recorded;
any other failure throws.

Each call replaces the exclusions of the previous call on the same system: it first sets available again
exactly the components that call disabled, then computes its own exclusions. Components it did not
disable, such as those unavailable in the input, are left as they are. Nothing is changed when it throws.

# Arguments
- `sys`: the replay system, mutated in place.
- `template`: the `PSI.ProblemTemplate` the replay builds, e.g. [`template_nemde`](@ref)().
- `exclude_constraints`: a `Dict` from the names of `GenericConstraint`s of `sys` to the `reason` each is
  recorded with; default empty.

# Returns
The records, sorted by constraint name. Throws `ArgumentError` for an unknown excluded constraint, or
for a constraint the template cannot model for a reason other than a missing FCAS service model or a
missing `PSY.AreaInterchange` model.
"""
function exclude_unmodeled_services!(
        sys::PSY.System, template::PSI.ProblemTemplate;
        exclude_constraints::AbstractDict{<:AbstractString, Symbol} = Dict{String, Symbol}(),
    )
    previous = pop!(PSY.get_ext(sys), _REPLAY_EXCLUSIONS_KEY, nothing)
    isnothing(previous) || _set_replay_availability!(sys, previous, true)
    rows = try
        _exclude_unmodeled_services!(sys, template, exclude_constraints)
    catch
        if !isnothing(previous)
            _set_replay_availability!(sys, previous, false)
            PSY.get_ext(sys)[_REPLAY_EXCLUSIONS_KEY] = previous
        end
        rethrow()
    end
    return rows
end


# Sets the `GenericConstraint`s named in `excluded` (keyed by the name of their type) to `available`.
function _set_replay_availability!(sys::PSY.System, excluded::AbstractDict, available::Bool)
    for name in get(excluded, string(nameof(GenericConstraint)), String[])
        PSY.set_available!(PSY.get_component(GenericConstraint, sys, name), available)
    end
    return
end


function _exclude_unmodeled_services!(
        sys::PSY.System, template::PSI.ProblemTemplate, exclude_constraints::AbstractDict{<:AbstractString, Symbol},
    )
    rows = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int}[]
    unavailable_constraints = String[]
    if _has_service_model(template, GenericConstraint)
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
        tolerated = _left_out_reasons(template)
        tolerated_types = _left_out_types(template)
        blocked = @NamedTuple{constraint::String, reason::Symbol}[]
        buildable = _filter_buildable_generic_constraints(
            sys, template, candidates; allow_partial_coverage = !isempty(tolerated) || !isempty(tolerated_types),
            skipped = rows, tolerated_reasons = tolerated, tolerated_types = tolerated_types, blocked = blocked,
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
    for name in unavailable_constraints
        PSY.set_available!(PSY.get_component(GenericConstraint, sys, name), false)
    end
    PSY.get_ext(sys)[_REPLAY_EXCLUSIONS_KEY] = Dict("GenericConstraint" => unavailable_constraints)
    sort!(rows; by = r -> r.constraint)
    return rows
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
