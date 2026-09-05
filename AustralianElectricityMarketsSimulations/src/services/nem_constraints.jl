"LHS expression for a [`GenericConstraint`](@ref): the weighted sum of its energy terms."
struct NEMConstraintLHS <: PSI.ExpressionType end

"`LHS <sense> RHS` constraint for one [`GenericConstraint`](@ref)."
struct NEMConstraintLimit <: PSI.ConstraintType end

"A [`GenericConstraint`](@ref)'s per-interval enforced RHS (`DISPATCHCONSTRAINT.RHS`, replayed)."
struct NEMConstraintRHSParameter <: PSI.TimeSeriesParameter end

"Formulation for [`GenericConstraint`](@ref) as a `PSI.Service`: energy terms only."
struct TermConstraint <: AbstractNEMConstraintFormulation end

PSI.get_default_time_series_names(::Type{GenericConstraint}, ::Type{TermConstraint}) =
    Dict{Type{<:PSI.TimeSeriesParameter}, String}(NEMConstraintRHSParameter => "rhs")

PSI.get_default_attributes(::Type{GenericConstraint}, ::Type{TermConstraint}) =
    Dict{String, Any}()

PSI.get_multiplier_value(::NEMConstraintRHSParameter, ::GenericConstraint, ::TermConstraint) =
    1.0

# --- Step 6: skip-whole-constraint-and-warn-once ---
#
# Scanned eagerly at ModelConstructStage (cached by `container`, for one summary `@warn`): PSI
# builds branches - where `AreaInterchange` lives - only after services' ArgumentConstructStage,
# so that's the earliest point every term's device is reliably checkable.
# `WeakKeyDict`, not `IdDict`: an `IdDict` would strongly reference every container key, leaking
# each built `OptimizationContainer` for the process's life.
const _NEM_CONSTRAINT_SKIP_CACHE = Base.WeakKeyDict{PSI.OptimizationContainer, Dict{String, Symbol}}()

_term_bid_type(term::Union{UnitTerm, RegionTerm}) = get_bid_type(term)

# `PSY.Storage` has no `ActivePowerVariable`: formulations split it into charge/discharge, netted
# by PSI's nodal balance via -1.0/+1.0 multipliers.
_energy_variables(::PSY.Storage) =
    ((PSI.ActivePowerOutVariable, 1.0), (PSI.ActivePowerInVariable, -1.0))
_energy_variables(::PSY.Device) = ((PSI.ActivePowerVariable, 1.0),)

_energy_modeled(container::PSI.OptimizationContainer, device::PSY.Device) = all(
    v -> PSI.has_container_key(container, first(v), typeof(device)),
    _energy_variables(device),
)

function _skip_reason(container::PSI.OptimizationContainer, sys::PSY.System, term::UnitTerm)
    _term_bid_type(term) != BidType.ENERGY && return :unsupported_bid_type
    device = PSY.get_component(PSY.Device, sys, get_duid(term))
    isnothing(device) && return :missing_component
    _energy_modeled(container, device) || return :unmodeled_device_type
    return nothing
end

function _skip_reason(container::PSI.OptimizationContainer, sys::PSY.System, term::RegionTerm)
    _term_bid_type(term) != BidType.ENERGY && return :unsupported_bid_type
    devices = AustralianElectricityMarkets._region_devices(sys, get_region(term))
    isempty(devices) && return :no_region_devices
    all(d -> _energy_modeled(container, d), devices) || return :unmodeled_device_type
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
            @warn "TermConstraint: skipped $(length(skipped)) of $(length(all_gcs)) GenericConstraints" reason_counts
        end
        return skipped
    end
end

# --- Step 3: add_to_expression! per term type ---
#
# Each method resolves its own term's device(s) directly from `sys`, not via PSI's flattened
# contributing-devices map - that would lose a term's own factor when two terms of different
# types share a device. Device variables are already per-unit; only `NEMConstraintRHSParameter`
# (a real natural-MW value) needs base-power conversion.

"Adds `factor * device's net injection` into `expr`, over every variable `_energy_variables` names."
function _add_device_energy_terms!(container, expr, name, device, factor)
    dname = PSY.get_name(device)
    for (var_type, multiplier) in _energy_variables(device)
        var = PSI.get_variable(container, var_type(), typeof(device))
        for t in PSI.get_time_steps(container)
            JuMP.add_to_expression!(expr[name, t], multiplier * factor, var[dname, t])
        end
    end
    return
end

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
    _add_device_energy_terms!(container, expr, name, device, get_factor(term))
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
        _add_device_energy_terms!(container, expr, name, device, get_factor(term))
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
        model::PSI.ServiceModel{GenericConstraint, TermConstraint},
    )
    name = PSY.get_name(gc)
    expr = PSI.get_expression(container, NEMConstraintLHS(), GenericConstraint, name)
    time_steps = PSI.get_time_steps(container)
    # Own container per constraint (`meta = name`): a skipped constraint never gets an entry, so a
    # shared container's blanket dual broadcast would hit `#undef` for it.
    con = PSI.lazy_container_addition!(
        container, NEMConstraintLimit(), GenericConstraint, [name], time_steps; meta = name,
    )
    rhs_param = PSI.get_parameter(container, NEMConstraintRHSParameter(), GenericConstraint, name)
    rhs_refs = PSI.get_parameter_column_refs(rhs_param, name)
    # `rhs_refs` is raw natural-MW; `expr`'s terms are already per-unit. Divide by base power here
    # - `get_multiplier_value` has no `container` to do the conversion itself.
    base_power = PSI.get_base_power(container)
    invoked = _invoked_mask(container, gc)
    jm = PSI.get_jump_model(container)
    sense = get_sense(gc)
    for t in time_steps
        if invoked[t] == 0.0
            # `con` is dense: an `#undef` cell throws `UndefRefError` on PSI's dual read-back. A
            # vacuous, disconnected constraint stays defined and reads back dual `0.0` instead.
            con[name, t] = JuMP.@constraint(jm, 0.0 <= 1.0)
            continue
        end
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
        model::PSI.ServiceModel{GenericConstraint, TermConstraint},
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
        model::PSI.ServiceModel{GenericConstraint, TermConstraint},
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

    # Not `PSI.add_constraint_dual!` - broken for a generic `Service` + `duals=` in installed PSI
    # 0.38.3; re-check this if PSI is upgraded.
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
    ::PSI.ServiceModel{GenericConstraint, TermConstraint},
) = nothing
