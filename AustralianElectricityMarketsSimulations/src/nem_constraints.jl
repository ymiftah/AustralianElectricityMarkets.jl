# `LinearFactorLimit` — the `GenericConstraint` `PSI.Service` formulation for energy terms
# (`InterconnectorTerm`, and `UnitTerm`/`RegionTerm` with `bid_type == BidType.ENERGY`). FCAS
# terms are a later formulation. Follows the `TransmissionInterface` extension pattern in
# installed PSI (`services_models/transmission_interface.jl`).

PSI.get_default_time_series_names(::Type{GenericConstraint}, ::Type{LinearFactorLimit}) =
    Dict{Type{<:PSI.TimeSeriesParameter}, String}(NEMConstraintRHSParameter => "rhs")

PSI.get_default_attributes(::Type{GenericConstraint}, ::Type{LinearFactorLimit}) =
    Dict{String, Any}()

PSI.get_multiplier_value(::NEMConstraintRHSParameter, ::GenericConstraint, ::LinearFactorLimit) =
    1.0

# --- Term validation: fail loudly, never a partial LHS ---

_term_bid_type(term::Union{UnitTerm, RegionTerm}) = get_bid_type(term)

"A device's ENERGY variables and each one's multiplier in its net injection. `PSY.Storage` has no
`ActivePowerVariable`: storage formulations split it into charge/discharge, which PSI's own
nodal balance nets with variable multipliers of -1.0 and +1.0."
_energy_variables(::PSY.Storage) =
    ((PSI.ActivePowerOutVariable, 1.0), (PSI.ActivePowerInVariable, -1.0))
_energy_variables(::PSY.Device) = ((PSI.ActivePowerVariable, 1.0),)

_energy_modeled(container::PSI.OptimizationContainer, device::PSY.Device) = all(
    v -> PSI.has_container_key(container, first(v), typeof(device)),
    _energy_variables(device),
)

"""
    _checked_device(container, sys, gc, term::UnitTerm) -> PSY.Device

Resolves `term`'s device and confirms the template models its energy variables. Throws
`ArgumentError` naming `gc`, `term` and the reason when the term's `bid_type` isn't
`BidType.ENERGY`, its device is absent from `sys`, or the device's energy variables aren't in
`container`.

# Returns
The resolved `PSY.Device`.
"""
function _checked_device(
        container::PSI.OptimizationContainer, sys::PSY.System, gc::GenericConstraint, term::UnitTerm,
    )
    name = PSY.get_name(gc)
    _term_bid_type(term) == BidType.ENERGY || throw(
        ArgumentError(
            "GenericConstraint \"$name\": UnitTerm on DUID \"$(get_duid(term))\" has bid_type " *
                "$(get_bid_type(term)); LinearFactorLimit only builds ENERGY terms.",
        ),
    )
    device = PSY.get_component(PSY.Device, sys, get_duid(term))
    isnothing(device) && throw(
        ArgumentError(
            "GenericConstraint \"$name\": UnitTerm's DUID \"$(get_duid(term))\" has no matching " *
                "component in `sys`.",
        ),
    )
    _energy_modeled(container, device) || throw(
        ArgumentError(
            "GenericConstraint \"$name\": UnitTerm's device \"$(get_duid(term))\" " *
                "($(typeof(device))) has no energy variables in this template; the template " *
                "must model $(typeof(device)).",
        ),
    )
    return device
end

"""
    _checked_devices(container, sys, gc, term::RegionTerm) -> Vector{PSY.Device}

Resolves `term`'s already-attributed devices ([`get_devices`](@ref)) and confirms the template
models each one's energy variables. Throws `ArgumentError` naming `gc`, `term` and the reason
when the term's `bid_type` isn't `BidType.ENERGY`, a device is absent from `sys`, or a device's
energy variables aren't in `container`.

# Returns
A `Vector{PSY.Device}`.
"""
function _checked_devices(
        container::PSI.OptimizationContainer, sys::PSY.System, gc::GenericConstraint, term::RegionTerm,
    )
    name = PSY.get_name(gc)
    _term_bid_type(term) == BidType.ENERGY || throw(
        ArgumentError(
            "GenericConstraint \"$name\": RegionTerm on region \"$(get_region(term))\" has " *
                "bid_type $(get_bid_type(term)); LinearFactorLimit only builds ENERGY terms.",
        ),
    )
    devices = PSY.Device[]
    for dname in get_devices(term)
        device = PSY.get_component(PSY.Device, sys, dname)
        isnothing(device) && throw(
            ArgumentError(
                "GenericConstraint \"$name\": RegionTerm on region \"$(get_region(term))\" " *
                    "names device \"$dname\", which has no matching component in `sys`.",
            ),
        )
        _energy_modeled(container, device) || throw(
            ArgumentError(
                "GenericConstraint \"$name\": RegionTerm on region \"$(get_region(term))\" " *
                    "device \"$dname\" ($(typeof(device))) has no energy variables in this " *
                    "template; the template must model $(typeof(device)).",
            ),
        )
        push!(devices, device)
    end
    return devices
end

"""
    _checked_interconnector(container, sys, gc, term::InterconnectorTerm) -> PSY.AreaInterchange

Resolves `term`'s `PSY.AreaInterchange` and confirms the template models
`PSI.FlowActivePowerVariable` for it. Throws `ArgumentError` naming `gc`, `term` and the reason
otherwise.

# Returns
The resolved `PSY.AreaInterchange`.
"""
function _checked_interconnector(
        container::PSI.OptimizationContainer, sys::PSY.System, gc::GenericConstraint,
        term::InterconnectorTerm,
    )
    name = PSY.get_name(gc)
    device = PSY.get_component(PSY.AreaInterchange, sys, get_interconnector(term))
    isnothing(device) && throw(
        ArgumentError(
            "GenericConstraint \"$name\": InterconnectorTerm's interconnector " *
                "\"$(get_interconnector(term))\" has no matching component in `sys`.",
        ),
    )
    PSI.has_container_key(container, PSI.FlowActivePowerVariable, PSY.AreaInterchange) || throw(
        ArgumentError(
            "GenericConstraint \"$name\": InterconnectorTerm's interconnector " *
                "\"$(get_interconnector(term))\" has no FlowActivePowerVariable in this " *
                "template; the template must model PSY.AreaInterchange.",
        ),
    )
    return device
end

# --- add_to_expression! per term type ---

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
    device = _checked_device(container, sys, gc, term)
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
    for device in _checked_devices(container, sys, gc, term)
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
    device = _checked_interconnector(container, sys, gc, term)
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

# --- add_constraints!: sense dispatch, honouring the "invoked" series ---

"""
    _invoked_mask(container, gc) -> Vector{Float64}

The `GenericConstraint`'s `"invoked"` `Deterministic` series (`1.0`/`0.0`), aligned to
`PSI.get_time_steps(container)`.

# Returns
A `Vector{Float64}`.
"""
function _invoked_mask(container::PSI.OptimizationContainer, gc::GenericConstraint)
    ts_type = PSI.get_default_time_series_type(container)
    return PSI.get_time_series_initial_values!(container, ts_type, gc, "invoked")
end

function PSI.add_constraints!(
        container::PSI.OptimizationContainer,
        ::Type{NEMConstraintLimit},
        gc::GenericConstraint,
        model::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
    )
    name = PSY.get_name(gc)
    expr = PSI.get_expression(container, NEMConstraintLHS(), GenericConstraint, name)
    time_steps = PSI.get_time_steps(container)
    # Own container per constraint instance (`meta = name`): a `NEMConstraintLimit`/dual
    # container shared across every `GenericConstraint` of this type would need every instance
    # built, and this package builds one `ServiceModel` entry per `GenericConstraint`.
    con = PSI.lazy_container_addition!(
        container, NEMConstraintLimit(), GenericConstraint, [name], time_steps; meta = name,
    )
    rhs_param = PSI.get_parameter(container, NEMConstraintRHSParameter(), GenericConstraint, name)
    rhs_refs = PSI.get_parameter_column_refs(rhs_param, name)
    invoked = _invoked_mask(container, gc)
    jm = PSI.get_jump_model(container)
    sense = get_sense(gc)
    for t in time_steps
        if invoked[t] == 0.0
            # The container spans every time step; PSI's dual read-back
            # (`_calculate_dual_variable_value!`) broadcasts over the whole thing, so an
            # unassigned cell throws `UndefRefError`. A vacuous, disconnected constraint
            # keeps the cell defined, adds no LHS, and reads back a dual of exactly `0.0`.
            con[name, t] = JuMP.@constraint(jm, 0.0 <= 1.0)
            continue
        end
        con[name, t] = if sense == ConstraintSense.LE
            JuMP.@constraint(jm, expr[name, t] <= rhs_refs[t])
        elseif sense == ConstraintSense.GE
            JuMP.@constraint(jm, expr[name, t] >= rhs_refs[t])
        else
            JuMP.@constraint(jm, expr[name, t] == rhs_refs[t])
        end
    end
    return
end

# --- construct_service!: argument + model stages ---

function PSI.construct_service!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ArgumentConstructStage,
        model::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
        devices_template::Dict{Symbol, PSI.DeviceModel},
        incompatible_device_types::Set{<:DataType},
        network_model::PSI.NetworkModel,
    )
    name = PSI.get_service_name(model)
    gc = PSY.get_component(GenericConstraint, sys, name)
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
        model::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
        devices_template::Dict{Symbol, PSI.DeviceModel},
        incompatible_device_types::Set{<:DataType},
        network_model::PSI.NetworkModel,
    )
    name = PSI.get_service_name(model)
    gc = PSY.get_component(GenericConstraint, sys, name)
    PSY.get_available(gc) || return

    for term in get_terms(gc)
        _add_gc_term_to_expression!(container, gc, term, sys)
    end

    PSI.add_constraints!(container, NEMConstraintLimit, gc, model)

    # Not `PSI.add_constraint_dual!(container, sys, model)`: `add_dual_container!` directly is
    # exactly what that method's scalar-`D<:PSY.Service` branch does internally.
    if !isempty(PSI.get_duals(model))
        time_steps = PSI.get_time_steps(container)
        for constraint_type in PSI.get_duals(model)
            PSI.add_dual_container!(
                container, constraint_type, GenericConstraint, [name], time_steps; meta = name,
            )
        end
    end

    PSI.objective_function!(container, gc, model)
    return
end

# GenericConstraints carry no cost of their own.
PSI.objective_function!(
    ::PSI.OptimizationContainer, ::GenericConstraint,
    ::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
) = nothing
