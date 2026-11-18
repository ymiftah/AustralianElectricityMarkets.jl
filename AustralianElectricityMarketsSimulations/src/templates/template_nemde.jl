"""
    template_nemde(;
        interconnectors = :losses, fcas = true, constraints = true, tie_break = true,
        exclude_constraints = Dict{String, Symbol}(), loss_breakpoints = nothing,
    ) -> PSI.ProblemTemplate

The keyword builder of the dispatch templates. The default builds the `PSI.ProblemTemplate` that models NEMDE dispatch:
[`NEMDispatch`](@ref) for each type of [`NEM_DISPATCH_DEVICE_TYPES`](@ref), including the batteries,
`PSI.StaticPowerLoad` demand, [`NEMInterconnectorLoss`](@ref) on each `PSY.AreaInterchange`, an [`FCASMarket`](@ref)
per `FCASService`, a [`LinearFactorLimit`](@ref) per `GenericConstraint` and the [`TieBreakMarket`](@ref) service
model, over `PSI.AreaBalancePowerModel` regions. The balance slacks carry PSI's default slack cost here; only
[`NEMDispatchProblem`](@ref) prices them at the Market Price Cap.

Each keyword removes or swaps one part. The presets [`template_energy_only`](@ref), [`template_interconnected`](@ref),
[`template_losses`](@ref), [`template_fcas`](@ref) and [`template_constraints`](@ref) are calls to this builder with
fixed keywords. [`check_template_against_sys`](@ref), [`check_fcas_services`](@ref) and [`template_skipped_constraints`](@ref)
read what is modeled from the template they are given.

# Arguments
- `interconnectors`: `:losses` models each `PSY.AreaInterchange` under [`NEMInterconnectorLoss`](@ref), `:lossless`
  under [`NEMInterconnectorLossless`](@ref) and `:none` leaves the interchanges out.
- `fcas`: whether the [`FCASMarket`](@ref) service model of each `FCASService` is included.
- `constraints`: `true` models every `GenericConstraint`, `:fcas_requirements` only those carrying FCAS requirements
  (it needs `fcas = true`, since FCAS requirements are constraints that clear nothing without the FCAS market),
  and `false` none.
- `tie_break`: whether the [`TieBreakMarket`](@ref) service model is included.
- `exclude_constraints`: a `Dict` from the names of `GenericConstraint`s to the reason each is recorded with.
  The run leaves these constraints out without changing the system; an unknown name fails the model's
  template validation. Needs `constraints` other than `false`. Default empty.
- `loss_breakpoints`: `nothing` reads every breakpoint of each interchange's loss model. An integer `N >= 2` keeps at
  most `N` of them, always the first and last and the interior thinned evenly by index, and applies to the interchange
  model at build without changing the system. Needs `interconnectors = :losses`.

# Returns
A `PSI.ProblemTemplate`.
"""
function template_nemde(;
        interconnectors::Symbol = :losses,
        fcas::Bool = true,
        constraints::Union{Bool, Symbol} = true,
        tie_break::Bool = true,
        exclude_constraints::AbstractDict{<:AbstractString, Symbol} = Dict{String, Symbol}(),
        loss_breakpoints::Union{Nothing, Integer} = nothing,
    )
    _validate_template_arguments(interconnectors, fcas, constraints, exclude_constraints, loss_breakpoints)
    template = PSI.ProblemTemplate(
        PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true, duals = [PSI.CopperPlateBalanceConstraint]),
    )
    for T in NEM_DISPATCH_DEVICE_TYPES
        PSI.set_device_model!(template, T, NEMDispatch)
    end
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    interchange = _interchange_model(interconnectors, loss_breakpoints)
    isnothing(interchange) || PSI.set_device_model!(template, interchange)
    if fcas
        PSI.set_service_model!(
            template,
            PSI.ServiceModel(FCASService, FCASMarket; duals = [FCASJointCapacityConstraint], use_slacks = true),
        )
    end
    if constraints !== false
        scope = constraints === :fcas_requirements ? :fcas_requirements : :all
        PSI.set_service_model!(template, _generic_constraint_model(exclude_constraints; scope))
    end
    if tie_break
        PSI.set_service_model!(template, PSI.ServiceModel(EnergyTieBreak, TieBreakMarket))
    end
    return template
end


# Throws `ArgumentError` for a combination of `template_nemde` keywords that does not build a template.
function _validate_template_arguments(
        interconnectors::Symbol, fcas::Bool, constraints::Union{Bool, Symbol},
        exclude_constraints::AbstractDict, loss_breakpoints::Union{Nothing, Integer},
    )
    interconnectors in (:none, :lossless, :losses) ||
        throw(ArgumentError("interconnectors must be :none, :lossless or :losses, got :$interconnectors"))
    constraints in (true, false, :fcas_requirements) ||
        throw(ArgumentError("constraints must be true, false or :fcas_requirements, got $(repr(constraints))"))
    constraints === :fcas_requirements && !fcas &&
        throw(ArgumentError("constraints = :fcas_requirements needs the FCAS service model; set fcas = true"))
    constraints === false && !isempty(exclude_constraints) &&
        throw(ArgumentError("exclude_constraints needs the GenericConstraint model; set constraints to true or :fcas_requirements"))
    if !isnothing(loss_breakpoints)
        interconnectors === :losses ||
            throw(ArgumentError("loss_breakpoints thins the loss model; set interconnectors = :losses"))
        loss_breakpoints >= 2 || throw(ArgumentError("loss_breakpoints must be at least 2, got $loss_breakpoints"))
    end
    return nothing
end


# The interchange device model of `interconnectors`, or `nothing` for `:none`. The breakpoint cap is an attribute,
# read when the interchanges are built.
function _interchange_model(interconnectors::Symbol, loss_breakpoints::Union{Nothing, Integer})
    interconnectors === :none && return nothing
    interconnectors === :lossless && return PSI.DeviceModel(PSY.AreaInterchange, NEMInterconnectorLossless)
    attributes = isnothing(loss_breakpoints) ? Dict{String, Any}() : Dict{String, Any}("loss_breakpoints" => Int(loss_breakpoints))
    return PSI.DeviceModel(PSY.AreaInterchange, NEMInterconnectorLoss; attributes)
end


"""
    template_energy_only() -> PSI.ProblemTemplate

The energy-only run: the dispatch participants and `PSI.StaticPowerLoad` demand of [`template_nemde`](@ref), with
no interchange, FCAS, generic constraint or tie-break model. It corresponds to nempy examples 1 and 2 (bid stack and
ramps). Those examples have no fast-start, so run them with `fast_start = false`, as in
`nem_dispatch_sequence(NEMDispatchProblem, template_energy_only(), sys; fast_start = false)`.

# Returns
A `PSI.ProblemTemplate`.
"""
function template_energy_only()
    return template_nemde(; interconnectors = :none, fcas = false, constraints = false, tie_break = false)
end


"""
    template_interconnected() -> PSI.ProblemTemplate

The energy run with the interchanges lossless: [`template_energy_only`](@ref) plus each `PSY.AreaInterchange` under
[`NEMInterconnectorLossless`](@ref), so its flow limits bind and no loss is taken. It leaves out losses, FCAS, generic
constraints and tie-break, and an MNSP is a regulated flow within its limits. It corresponds to nempy example 3, which
is a constant 5 percent loss rather than lossless. Run it with `fast_start = false`, as in
`nem_dispatch_sequence(NEMDispatchProblem, template_interconnected(), sys; fast_start = false)`.

# Returns
A `PSI.ProblemTemplate`.
"""
function template_interconnected()
    return template_nemde(; interconnectors = :lossless, fcas = false, constraints = false, tie_break = false)
end


"""
    template_losses(; loss_breakpoints = nothing) -> PSI.ProblemTemplate

The energy run with the interchanges under [`NEMInterconnectorLoss`](@ref): [`template_energy_only`](@ref) plus the
dynamic loss model of each interchange. It leaves out FCAS, generic constraints and tie-break. It corresponds to
nempy example 4. Run it with `fast_start = false`, as in
`nem_dispatch_sequence(NEMDispatchProblem, template_losses(), sys; fast_start = false)`.

# Arguments
- `loss_breakpoints`: `nothing`, or an integer `N >= 2` keeping at most `N` breakpoints of each loss model, as in
  [`template_nemde`](@ref).

# Returns
A `PSI.ProblemTemplate`.
"""
function template_losses(; loss_breakpoints::Union{Nothing, Integer} = nothing)
    return template_nemde(;
        interconnectors = :losses, fcas = false, constraints = false, tie_break = false, loss_breakpoints,
    )
end


"""
    template_fcas(; loss_breakpoints = nothing) -> PSI.ProblemTemplate

[`template_losses`](@ref) plus the FCAS market, with the generic constraints restricted to those carrying FCAS
requirements (`constraints = :fcas_requirements`): FCAS clears only against its requirements. It leaves out the other
generic constraints and tie-break. It corresponds to nempy example 5. Run it with `fast_start = false`, as in
`nem_dispatch_sequence(NEMDispatchProblem, template_fcas(), sys; fast_start = false)`.

# Arguments
- `loss_breakpoints`: `nothing`, or an integer `N >= 2` keeping at most `N` breakpoints of each loss model, as in
  [`template_nemde`](@ref).

# Returns
A `PSI.ProblemTemplate`.
"""
function template_fcas(; loss_breakpoints::Union{Nothing, Integer} = nothing)
    return template_nemde(;
        interconnectors = :losses, fcas = true, constraints = :fcas_requirements, tie_break = false, loss_breakpoints,
    )
end


"""
    template_constraints(; exclude_constraints = Dict{String, Symbol}(), loss_breakpoints = nothing) -> PSI.ProblemTemplate

[`template_losses`](@ref) plus every `GenericConstraint`, without the FCAS market or tie-break. Constraints with FCAS
terms are left out and reported by [`template_skipped_constraints`](@ref) as `:unmodeled_fcas_service`. It has no
nempy counterpart. Run it with `fast_start = false`, as in
`nem_dispatch_sequence(NEMDispatchProblem, template_constraints(), sys; fast_start = false)`.

# Arguments
- `exclude_constraints`: as in [`template_nemde`](@ref).
- `loss_breakpoints`: `nothing`, or an integer `N >= 2` keeping at most `N` breakpoints of each loss model, as in
  [`template_nemde`](@ref).

# Returns
A `PSI.ProblemTemplate`.
"""
function template_constraints(;
        exclude_constraints::AbstractDict{<:AbstractString, Symbol} = Dict{String, Symbol}(),
        loss_breakpoints::Union{Nothing, Integer} = nothing,
    )
    return template_nemde(;
        interconnectors = :losses, fcas = false, constraints = true, tie_break = false,
        exclude_constraints, loss_breakpoints,
    )
end


"""
    _generic_constraint_model(exclude_constraints; scope = :all) -> PSI.ServiceModel

The aggregated `GenericConstraint` service model of [`template_nemde`](@ref). Its `"filter_function"` attribute
leaves the constraints named in `exclude_constraints` and the constraints outside `scope` out of PSI's per-name
expansion, and its `"excluded_constraints"` and `"constraint_scope"` attributes record the exclusions and the scope.
"""
function _generic_constraint_model(exclude_constraints::AbstractDict{<:AbstractString, Symbol}; scope::Symbol = :all)
    excluded = Dict{String, Symbol}(exclude_constraints)
    return PSI.ServiceModel(
        GenericConstraint, LinearFactorLimit; duals = [NEMConstraintLimit], use_slacks = true,
        attributes = Dict{String, Any}(
            "filter_function" => gc -> !haskey(excluded, PSY.get_name(gc)) && _in_constraint_scope(gc, scope),
            "excluded_constraints" => excluded,
            "constraint_scope" => scope,
        ),
    )
end


"""
    _in_constraint_scope(gc, scope) -> Bool

Whether `gc` belongs to the constraint scope `scope`: every constraint for `:all`, and only those carrying
FCAS requirements for `:fcas_requirements`.

# Returns
`Bool`.
"""
function _in_constraint_scope(gc::GenericConstraint, scope::Symbol)
    scope === :all && return true
    scope === :fcas_requirements && return !isempty(AustralianElectricityMarkets.get_fcas_requirements(gc))
    throw(ArgumentError("unknown constraint scope :$scope; choose :all or :fcas_requirements"))
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
    _has_interconnector_loss_model(template) -> Bool

Whether `template` models a `PSY.AreaInterchange` under [`NEMInterconnectorLoss`](@ref), the only
interchange formulation that carries MNSP link offers.

# Returns
`Bool`.
"""
function _has_interconnector_loss_model(template::PSI.ProblemTemplate)
    return any(
        m -> PSI.get_component_type(m) <: PSY.AreaInterchange && PSI.get_formulation(m) <: NEMInterconnectorLoss,
        values(PSI.get_branch_models(template)),
    )
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
