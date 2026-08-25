# NEM `GenericConstraint`s as a `PowerSimulations.jl` `Service` — energy terms only
# (`InterconnectorTerm`, and `UnitTerm`/`RegionTerm` with `bid_type == BidType.ENERGY`). FCAS
# terms are a later task. Follows the `TransmissionInterface` extension pattern in installed
# PSI (`services_models/transmission_interface.jl`); the `_modify_device_model!` no-op this
# needs lives in `psi_compat.jl`, not here (isolated on purpose — see that file).

"LHS expression for a [`GenericConstraint`](@ref): the weighted sum of its energy terms."
struct NEMConstraintLHS <: PSI.ExpressionType end

"`LHS <sense> RHS` constraint for one [`GenericConstraint`](@ref)."
struct NEMConstraintLimit <: PSI.ConstraintType end

"A [`GenericConstraint`](@ref)'s per-interval enforced RHS (`DISPATCHCONSTRAINT.RHS`, replayed)."
struct NEMConstraintRHSParameter <: PSI.TimeSeriesParameter end

"Formulation for [`GenericConstraint`](@ref) as a `PSI.Service`: energy terms only."
struct NEMGenericConstraint <: PSI.AbstractServiceFormulation end

PSI.get_default_time_series_names(::Type{GenericConstraint}, ::Type{NEMGenericConstraint}) =
    Dict{Type{<:PSI.TimeSeriesParameter}, String}(NEMConstraintRHSParameter => "rhs")

PSI.get_default_attributes(::Type{GenericConstraint}, ::Type{NEMGenericConstraint}) =
    Dict{String, Any}()

PSI.get_multiplier_value(::NEMConstraintRHSParameter, ::GenericConstraint, ::NEMGenericConstraint) =
    1.0

# --- Step 6: skip-whole-constraint-and-warn-once ---
#
# A constraint referencing a component absent from `sys`, an unsupported (non-ENERGY) bid_type,
# or a device type this template doesn't model is skipped whole, never with a partial LHS -
# mirrors `add_nem_constraints!`'s own skip behaviour. PSI expands one `GenericConstraint` into
# its own `ServiceModel` entry per instance (`problem_template.jl:_populate_aggregated_service_model!`)
# and calls `construct_service!` once per entry with no hook that sees them all at once, so
# every constraint is scanned eagerly on the first `ModelConstructStage` call (cached by
# `container` identity) to still get one summary `@warn`. The scan can only happen at
# `ModelConstructStage`: PSI builds branches (where `AreaInterchange` lives) *after* services'
# `ArgumentConstructStage` but *before* services' `ModelConstructStage`
# (`core/optimization_container.jl:build_impl!`), so an interconnector term's device isn't
# reliably checkable any earlier.
const _NEM_CONSTRAINT_SKIP_CACHE = Base.IdDict{PSI.OptimizationContainer, Dict{String, Symbol}}()

_term_bid_type(term::Union{UnitTerm, RegionTerm}) = get_bid_type(term)

function _skip_reason(container::PSI.OptimizationContainer, sys::PSY.System, term::UnitTerm)
    _term_bid_type(term) != BidType.ENERGY && return :unsupported_bid_type
    device = PSY.get_component(PSY.Device, sys, get_duid(term))
    isnothing(device) && return :missing_component
    PSI.has_container_key(container, PSI.ActivePowerVariable, typeof(device)) ||
        return :unmodeled_device_type
    return nothing
end

function _skip_reason(container::PSI.OptimizationContainer, sys::PSY.System, term::RegionTerm)
    _term_bid_type(term) != BidType.ENERGY && return :unsupported_bid_type
    devices = AustralianElectricityMarkets._region_devices(sys, get_region(term))
    isempty(devices) && return :no_region_devices
    any(d -> !PSI.has_container_key(container, PSI.ActivePowerVariable, typeof(d)), devices) &&
        return :unmodeled_device_type
    return nothing
end

function _skip_reason(container::PSI.OptimizationContainer, sys::PSY.System, term::InterconnectorTerm)
    device = PSY.get_component(PSY.AreaInterchange, sys, get_interconnector(term))
    isnothing(device) && return :missing_component
    PSI.has_container_key(container, PSI.FlowActivePowerVariable, PSY.AreaInterchange) ||
        return :unmodeled_device_type
    return nothing
end

function _skip_reason(container::PSI.OptimizationContainer, sys::PSY.System, gc::GenericConstraint)
    for term in get_terms(gc)
        reason = _skip_reason(container, sys, term)
        isnothing(reason) || return reason
    end
    return nothing
end

"""
    _skip_reasons!(container, sys) -> Dict{String, Symbol}

`GENCONID => reason` for every [`GenericConstraint`](@ref) in `sys` that this template can't
build (see the module-level comment above). Computed once per `container` and cached by object
identity; a nonempty result is reported as one summary `@warn` with counts by reason, not one
per constraint.
"""
function _skip_reasons!(container::PSI.OptimizationContainer, sys::PSY.System)
    return get!(_NEM_CONSTRAINT_SKIP_CACHE, container) do
        all_gcs = collect(PSY.get_components(GenericConstraint, sys))
        skipped = Dict{String, Symbol}()
        for gc in all_gcs
            reason = _skip_reason(container, sys, gc)
            isnothing(reason) || (skipped[PSY.get_name(gc)] = reason)
        end
        if !isempty(skipped)
            reason_counts = Dict{Symbol, Int}()
            for reason in values(skipped)
                reason_counts[reason] = get(reason_counts, reason, 0) + 1
            end
            @warn "NEMGenericConstraint: skipped $(length(skipped)) of $(length(all_gcs)) GenericConstraints" reason_counts
        end
        return skipped
    end
end

# --- Step 3: add_to_expression! per term type ---
#
# Each method resolves its own term's device(s) from `sys` directly (rather than from
# `PSI.get_contributing_devices_map(model)`, which flattens every term's devices into one
# per-type list and would lose a term's own factor when two terms of different types share a
# device) and adds `factor * device's ActivePowerVariable` (or, for an interconnector,
# `FlowActivePowerVariable`) into the constraint's LHS expression - the `InterfaceTotalFlow`
# pattern (`add_to_expression.jl`), adapted for per-term rather than per-service assembly.
# Callers only reach these once `_skip_reason` has confirmed every device is present and
# modeled, so no defensive `has_container_key` checks are repeated here.
#
# `get_factor(term)` multiplies the device variable directly, with no per-unit conversion:
# `ActivePowerVariable`/`FlowActivePowerVariable` are themselves already in per-unit of
# `PSI.get_base_power(container)`, and a `ConstraintTerm.factor` is a dimensionless multiplier
# on that same quantity (AEMO's own `FACTOR` columns are ratios, e.g. `-1.0` to net a flow), so
# it carries no MW units to convert. Only `NEMConstraintRHSParameter` - a real natural-MW
# value - needs the base-power conversion, applied in `add_constraints!`.

function PSI.add_to_expression!(
        container::PSI.OptimizationContainer,
        ::Type{NEMConstraintLHS},
        ::Type{UnitTerm},
        gc::GenericConstraint,
        term::UnitTerm,
        sys::PSY.System,
    )
    name = PSY.get_name(gc)
    expr = PSI.get_expression(container, NEMConstraintLHS(), GenericConstraint, name)
    device = PSY.get_component(PSY.Device, sys, get_duid(term))
    var = PSI.get_variable(container, PSI.ActivePowerVariable(), typeof(device))
    dname = PSY.get_name(device)
    for t in PSI.get_time_steps(container)
        JuMP.add_to_expression!(expr[name, t], get_factor(term), var[dname, t])
    end
    return
end

function PSI.add_to_expression!(
        container::PSI.OptimizationContainer,
        ::Type{NEMConstraintLHS},
        ::Type{RegionTerm},
        gc::GenericConstraint,
        term::RegionTerm,
        sys::PSY.System,
    )
    name = PSY.get_name(gc)
    expr = PSI.get_expression(container, NEMConstraintLHS(), GenericConstraint, name)
    for device in AustralianElectricityMarkets._region_devices(sys, get_region(term))
        var = PSI.get_variable(container, PSI.ActivePowerVariable(), typeof(device))
        dname = PSY.get_name(device)
        for t in PSI.get_time_steps(container)
            JuMP.add_to_expression!(expr[name, t], get_factor(term), var[dname, t])
        end
    end
    return
end

function PSI.add_to_expression!(
        container::PSI.OptimizationContainer,
        ::Type{NEMConstraintLHS},
        ::Type{InterconnectorTerm},
        gc::GenericConstraint,
        term::InterconnectorTerm,
        sys::PSY.System,
    )
    name = PSY.get_name(gc)
    expr = PSI.get_expression(container, NEMConstraintLHS(), GenericConstraint, name)
    device = PSY.get_component(PSY.AreaInterchange, sys, get_interconnector(term))
    var = PSI.get_variable(container, PSI.FlowActivePowerVariable(), PSY.AreaInterchange)
    dname = PSY.get_name(device)
    for t in PSI.get_time_steps(container)
        JuMP.add_to_expression!(expr[name, t], get_factor(term), var[dname, t])
    end
    return
end

function _add_gc_term_to_expression!(container, gc, term::UnitTerm, sys)
    PSI.add_to_expression!(container, NEMConstraintLHS, UnitTerm, gc, term, sys)
    return
end
function _add_gc_term_to_expression!(container, gc, term::RegionTerm, sys)
    PSI.add_to_expression!(container, NEMConstraintLHS, RegionTerm, gc, term, sys)
    return
end
function _add_gc_term_to_expression!(container, gc, term::InterconnectorTerm, sys)
    PSI.add_to_expression!(container, NEMConstraintLHS, InterconnectorTerm, gc, term, sys)
    return
end

# --- Step 4: add_constraints! with sense dispatch, honouring the "invoked" series ---

"""
    _invoked_mask(container, gc) -> Vector{Float64}

The `GenericConstraint`'s `"invoked"` `Deterministic` series (`1.0`/`0.0`), aligned to
`PSI.get_time_steps(container)` - see `add_nem_constraints!`'s docstring for why a
carried-forward `"rhs"` value must never be treated as enforced without checking this.
"""
function _invoked_mask(container::PSI.OptimizationContainer, gc::GenericConstraint)
    ts_type = PSI.get_default_time_series_type(container)
    return PSI.get_time_series_initial_values!(container, ts_type, gc, "invoked")
end

function PSI.add_constraints!(
        container::PSI.OptimizationContainer,
        ::Type{NEMConstraintLimit},
        gc::GenericConstraint,
        model::PSI.ServiceModel{GenericConstraint, NEMGenericConstraint},
    )
    name = PSY.get_name(gc)
    expr = PSI.get_expression(container, NEMConstraintLHS(), GenericConstraint, name)
    time_steps = PSI.get_time_steps(container)
    # Own container per constraint instance (`meta = name`), not one shared across every
    # `GenericConstraint` of this type: a skipped constraint (Step 6) never gets a
    # `NEMConstraintLimit`/dual entry at all, so `calculate_dual_variables!`'s blanket
    # broadcast over a *shared* container's rows would hit `#undef` for it. `TransmissionInterface`
    # can share one container because every registered interface always gets built; we can't,
    # since we skip whole instances.
    con = PSI.lazy_container_addition!(
        container, NEMConstraintLimit(), GenericConstraint, [name], time_steps; meta = name,
    )
    rhs_param = PSI.get_parameter(container, NEMConstraintRHSParameter(), GenericConstraint, name)
    rhs_refs = PSI.get_parameter_column_refs(rhs_param, name)
    # `rhs_refs` holds the raw natural-MW "rhs" series value (`get_multiplier_value` is 1.0,
    # see its docstring); `expr`'s terms are already per-unit (device variables are). Divide by
    # the base power here rather than fighting `get_multiplier_value`'s signature - it has no
    # `container` to read the base power from.
    base_power = PSI.get_base_power(container)
    invoked = _invoked_mask(container, gc)
    jm = PSI.get_jump_model(container)
    sense = get_sense(gc)
    for t in time_steps
        invoked[t] == 0.0 && continue
        con[name, t] = if sense == ConstraintSense.LE
            JuMP.@constraint(jm, expr[name, t] <= rhs_refs[t] / base_power)
        elseif sense == ConstraintSense.GE
            JuMP.@constraint(jm, expr[name, t] >= rhs_refs[t] / base_power)
        else
            JuMP.@constraint(jm, expr[name, t] == rhs_refs[t] / base_power)
        end
    end
    return
end

# --- Step 5: construct_service! argument + model stages ---

function PSI.construct_service!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ArgumentConstructStage,
        model::PSI.ServiceModel{GenericConstraint, NEMGenericConstraint},
        devices_template::Dict{Symbol, PSI.DeviceModel},
        incompatible_device_types::Set{<:DataType},
        network_model::PSI.NetworkModel,
    )
    name = PSI.get_service_name(model)
    gc = PSY.get_component(GenericConstraint, sys, name)
    # `meta = name`: this constraint's own expression container, not one shared across every
    # `GenericConstraint` of this type (see the "Step 4" comment on `add_constraints!` for why).
    PSI.lazy_container_addition!(
        container, NEMConstraintLHS(), GenericConstraint, [name], PSI.get_time_steps(container);
        meta = name,
    )
    PSI.add_parameters!(container, NEMConstraintRHSParameter, gc, model)
    return
end

function PSI.construct_service!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ModelConstructStage,
        model::PSI.ServiceModel{GenericConstraint, NEMGenericConstraint},
        devices_template::Dict{Symbol, PSI.DeviceModel},
        incompatible_device_types::Set{<:DataType},
        network_model::PSI.NetworkModel,
    )
    name = PSI.get_service_name(model)
    gc = PSY.get_component(GenericConstraint, sys, name)
    !PSY.get_available(gc) && return

    skipped = _skip_reasons!(container, sys)
    haskey(skipped, name) && return

    for term in get_terms(gc)
        _add_gc_term_to_expression!(container, gc, term, sys)
    end

    PSI.add_constraints!(container, NEMConstraintLimit, gc, model)

    # Not `PSI.add_constraint_dual!(container, sys, model)` - broken for any generic `Service` +
    # `duals=` in installed PSI 0.38.3 (Task 0 spike finding #1). `add_dual_container!` directly
    # is exactly what that method's scalar-`D<:PSY.Service` branch does internally. `meta = name`
    # for the same reason as the constraint container above: a skipped instance must never
    # register a dual container at all.
    if !isempty(PSI.get_duals(model))
        time_steps = PSI.get_time_steps(container)
        for constraint_type in PSI.get_duals(model)
            PSI.add_dual_container!(container, constraint_type, GenericConstraint, [name], time_steps; meta = name)
        end
    end

    PSI.objective_function!(container, gc, model)
    return
end

# GenericConstraints carry no cost of their own (AEMC constraint-violation penalties are a
# simulation-level concern, not modeled here).
PSI.objective_function!(
    ::PSI.OptimizationContainer, ::GenericConstraint,
    ::PSI.ServiceModel{GenericConstraint, NEMGenericConstraint},
) = nothing
