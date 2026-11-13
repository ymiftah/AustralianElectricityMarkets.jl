"""
    template_nemde(; exclude_constraints = Dict{String, Symbol}()) -> PSI.ProblemTemplate

Builds the `PSI.ProblemTemplate` that replicates NEMDE. It models [`NEMReplayDispatch`](@ref) for each
type of [`NEM_DISPATCH_DEVICE_TYPES`](@ref), including the batteries, `PSI.StaticPowerLoad` demand,
[`NEMInterconnectorLoss`](@ref) on each `PSY.AreaInterchange`, an [`FCASMarket`](@ref) per `FCASService`,
a [`LinearFactorLimit`](@ref) per `GenericConstraint` and the [`TieBreakMarket`](@ref) service model, over
`PSI.AreaBalancePowerModel` regions. The balance slacks carry PSI's default slack cost here; only
[`NEMDispatchProblem`](@ref) prices them at the Market Price Cap.

A replay that models less builds its own `PSI.ProblemTemplate` and passes it in.
[`check_template_against_sys`](@ref), [`check_fcas_services`](@ref) and [`replay_skipped_constraints`](@ref)
read what is modeled from the template they are given.

# Arguments
- `exclude_constraints`: a `Dict` from the names of `GenericConstraint`s to the reason each is recorded with.
  The replay leaves these constraints out without changing the system; an unknown name fails the model's
  template validation. Default empty.

# Returns
A `PSI.ProblemTemplate`.
"""
function template_nemde(; exclude_constraints::AbstractDict{<:AbstractString, Symbol} = Dict{String, Symbol}())
    template = PSI.ProblemTemplate(
        PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true, duals = [PSI.CopperPlateBalanceConstraint]),
    )
    for T in NEM_DISPATCH_DEVICE_TYPES
        PSI.set_device_model!(template, T, NEMReplayDispatch)
    end
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_device_model!(template, PSY.AreaInterchange, NEMInterconnectorLoss)
    PSI.set_service_model!(
        template,
        PSI.ServiceModel(FCASService, FCASMarket; duals = [FCASJointCapacityConstraint], use_slacks = true),
    )
    PSI.set_service_model!(template, _generic_constraint_model(exclude_constraints))
    PSI.set_service_model!(template, PSI.ServiceModel(EnergyTieBreak, TieBreakMarket))
    return template
end


"""
    _generic_constraint_model(exclude_constraints) -> PSI.ServiceModel

The aggregated `GenericConstraint` service model of [`template_nemde`](@ref). Its `"filter_function"` attribute
leaves the constraints named in `exclude_constraints` out of PSI's per-name expansion, and its
`"excluded_constraints"` attribute records their reasons for [`replay_skipped_constraints`](@ref).
"""
function _generic_constraint_model(exclude_constraints::AbstractDict{<:AbstractString, Symbol})
    excluded = Dict{String, Symbol}(exclude_constraints)
    return PSI.ServiceModel(
        GenericConstraint, LinearFactorLimit; duals = [NEMConstraintLimit], use_slacks = true,
        attributes = Dict{String, Any}(
            "filter_function" => gc -> !haskey(excluded, PSY.get_name(gc)), "excluded_constraints" => excluded,
        ),
    )
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
