# `LinearFactorLimit` — the `GenericConstraint` `PSI.Service` formulation for energy terms
# (`InterconnectorTerm`, and `UnitTerm`/`RegionTerm` with `bid_type == BidType.ENERGY`) and FCAS
# terms (`UnitTerm`/`RegionTerm` with an FCAS `bid_type`, read off `FCASMarket`'s variables).
# Follows the `TransmissionInterface` extension pattern in installed PSI
# (`services_models/transmission_interface.jl`).

PSI.get_default_time_series_names(::Type{GenericConstraint}, ::Type{LinearFactorLimit}) =
    Dict{Type{<:PSI.TimeSeriesParameter}, String}(NEMConstraintRHSParameter => "rhs")


PSI.get_default_attributes(::Type{GenericConstraint}, ::Type{LinearFactorLimit}) =
    Dict{String, Any}()


PSI.get_multiplier_value(::NEMConstraintRHSParameter, ::GenericConstraint, ::LinearFactorLimit) =
    1.0


"""
    MARKET_PRICE_CAP_BY_FINANCIAL_YEAR

Published Market Price Cap (`\$/MWh`), by the `Date` its financial year starts (1 July).
Source: AEMC *Schedule of reliability settings, 2026-27 financial year* (FY2024-25: AEMC's
2024-25 schedule).
"""
const MARKET_PRICE_CAP_BY_FINANCIAL_YEAR = [
    Date(2024, 7, 1) => 17_500.0,
    Date(2025, 7, 1) => 20_300.0,
    Date(2026, 7, 1) => 23_200.0,
]


"""
    _financial_year_mpc(t::DateTime) -> Float64

The published Market Price Cap for the financial year of the dispatch interval ending at `t` (a
`SETTLEMENTDATE`). The interval ending 00:00 on 1 July runs 23:55-00:00 on 30 June, so it takes the
earlier year's cap.

# Returns
A `\$/MWh` value.
"""
function _financial_year_mpc(t::DateTime)
    start = t - DISPATCH_INTERVAL
    year_start = Date(year(start) - (month(start) < 7), 7, 1)
    idx = findfirst(p -> p[1] == year_start, MARKET_PRICE_CAP_BY_FINANCIAL_YEAR)
    isnothing(idx) && throw(
        ArgumentError(
            "No published Market Price Cap covers $t; extend MARKET_PRICE_CAP_BY_FINANCIAL_YEAR " *
                "or set the \"market_price_cap\" entry of `PSI.get_ext(PSI.get_settings(model))`.",
        ),
    )
    return MARKET_PRICE_CAP_BY_FINANCIAL_YEAR[idx][2]
end


"""
    _container_market_price_cap(container, t::DateTime) -> Float64

The `"market_price_cap"` entry of the model's `PSI.get_ext(PSI.get_settings(model))`, or
[`_financial_year_mpc`](@ref)`(t)` if unset. The cap of every penalty priced by
[`_add_mpc_penalty!`](@ref), and the fallback of [`_service_market_price_cap`](@ref).

# Arguments
  - `container`: the `PSI.OptimizationContainer` being built.
  - `t`: the interval's timestamp.

# Returns
A finite, strictly positive `\$/MWh` value; invalid overrides throw `ArgumentError`.
"""
function _container_market_price_cap(container::PSI.OptimizationContainer, t::DateTime)
    rate = get(PSI.get_ext(PSI.get_settings(container)), "market_price_cap", nothing)
    return _checked_market_price_cap(isnothing(rate) ? _financial_year_mpc(t) : rate)
end


function _checked_market_price_cap(rate)
    rate isa Real || throw(ArgumentError("market_price_cap must be finite and strictly positive, got $rate."))
    value = Float64(rate)
    isfinite(value) && value > 0.0 ||
        throw(ArgumentError("market_price_cap must be finite and strictly positive, got $rate."))
    return value
end


# --- Term validation: fail loudly, never a partial LHS ---

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
`ArgumentError` naming `gc`, `term` and the reason when its device is absent from `sys`, or an
available device's energy variables aren't in `container`.

# Returns
The resolved `PSY.Device`.
"""
function _checked_device(
        container::PSI.OptimizationContainer, sys::PSY.System, gc::GenericConstraint, term::UnitTerm,
    )
    name = PSY.get_name(gc)
    device = PSY.get_component(PSY.Device, sys, get_duid(term))
    isnothing(device) && throw(
        ArgumentError(
            "GenericConstraint \"$name\": UnitTerm's DUID \"$(get_duid(term))\" has no matching " *
                "component in `sys`.",
        ),
    )
    PSY.get_available(device) && !_energy_modeled(container, device) && throw(
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
when a device is absent from `sys`, or an available device's energy variables aren't in `container`.

# Returns
A `Vector{PSY.Device}`.
"""
function _checked_devices(
        container::PSI.OptimizationContainer, sys::PSY.System, gc::GenericConstraint, term::RegionTerm,
    )
    name = PSY.get_name(gc)
    devices = PSY.Device[]
    for dname in get_devices(term)
        device = PSY.get_component(PSY.Device, sys, dname)
        isnothing(device) && throw(
            ArgumentError(
                "GenericConstraint \"$name\": RegionTerm on region \"$(get_region(term))\" " *
                    "names device \"$dname\", which has no matching component in `sys`.",
            ),
        )
        PSY.get_available(device) && !_energy_modeled(container, device) && throw(
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
    PSY.get_available(device) && !PSI.has_container_key(container, PSI.FlowActivePowerVariable, PSY.AreaInterchange) && throw(
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
    PSY.get_available(device) || return  # unavailable devices have no variables: they contribute zero
    dname = PSY.get_name(device)
    for (var_type, multiplier) in _energy_variables(device)
        var = PSI.get_variable(container, var_type(), typeof(device))
        for t in PSI.get_time_steps(container)
            JuMP.add_to_expression!(expr[name, t], multiplier * factor, var[dname, t])
        end
    end
    return
end


"""
    _add_device_fcas_terms!(container, expr, sys, gc, device, bid_type, factor)

Adds `factor` times `device`'s enablement of its [`fcas_service_name`](@ref) service into `expr`:
its [`FCASCapacityVariable`](@ref) for a contingency service, or its
[`FCASUnitRegulationTarget`](@ref) for a regulation service (the net gen + load target, AEMO
*FCAS Model in NEMDE* §2.4). Adds nothing when the service is absent, unavailable or has no
available devices, or `device` has no variable in it. Throws `ArgumentError` when the service has
devices but the template sets no [`FCASMarket`](@ref) model for it.
"""
function _add_device_fcas_terms!(container, expr, sys, gc, device, bid_type::BidType, factor)
    svc_name = fcas_service_name(device, bid_type)
    svc = PSY.get_component(FCASService, sys, svc_name)
    (isnothing(svc) || !PSY.get_available(svc)) && return
    dname = PSY.get_name(device)
    regulation = bid_type in FCAS_REGULATION_MARKETS
    key_type = regulation ? FCASUnitRegulationTarget : FCASCapacityVariable
    if !PSI.has_container_key(container, key_type, FCASService, svc_name)
        any(PSY.get_available, PSY.get_contributing_devices(sys, svc)) || return
        throw(
            ArgumentError(
                "GenericConstraint \"$(PSY.get_name(gc))\": term on \"$dname\" references FCASService " *
                    "\"$svc_name\", which has no $(nameof(key_type)) in this template; the template " *
                    "must set an FCASMarket model for it.",
            ),
        )
    end
    fcas = regulation ?
        PSI.get_expression(container, FCASUnitRegulationTarget(), FCASService, svc_name) :
        PSI.get_variable(container, FCASCapacityVariable(), FCASService, svc_name)
    dname in axes(fcas, 1) || return
    for t in PSI.get_time_steps(container)
        JuMP.add_to_expression!(expr[PSY.get_name(gc), t], factor, fcas[dname, t])
    end
    return
end


"""
    _warn_absent_fcas_services(sys, gc)

Warns once for `gc`, naming every FCAS service its terms reference that is absent from `sys`
(those terms contribute zero).
"""
function _warn_absent_fcas_services(sys::PSY.System, gc::GenericConstraint)
    absent = Set{String}()
    for term in get_terms(gc)
        term isa Union{UnitTerm, RegionTerm} || continue
        get_bid_type(term) == BidType.ENERGY && continue
        names = term isa UnitTerm ? [get_duid(term)] : get_devices(term)
        for dname in names
            device = PSY.get_component(PSY.Device, sys, dname)
            isnothing(device) && continue
            svc_name = fcas_service_name(device, get_bid_type(term))
            isnothing(PSY.get_component(FCASService, sys, svc_name)) && push!(absent, svc_name)
        end
    end
    isempty(absent) || @warn(
        "GenericConstraint \"$(PSY.get_name(gc))\": FCAS terms reference services absent from the " *
            "System and contribute zero: $(join(sort!(collect(absent)), ", "))."
    )
    return
end


"Adds `device`'s `bid_type` term to `expr`: its energy injection for `ENERGY`, else its FCAS enablement."
function _add_device_terms!(container, expr, sys, gc, device, bid_type::BidType, factor)
    if bid_type == BidType.ENERGY
        _add_device_energy_terms!(container, expr, PSY.get_name(gc), device, factor)
    else
        _add_device_fcas_terms!(container, expr, sys, gc, device, bid_type, factor)
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
    _add_device_terms!(container, expr, sys, gc, device, get_bid_type(term), get_factor(term))
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
        _add_device_terms!(container, expr, sys, gc, device, get_bid_type(term), get_factor(term))
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
    PSY.get_available(device) || return  # no flow variable: contributes zero
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


"""
    _add_gc_slack_variables!(container, gc, model)

Builds [`GenericConstraintSlackUp`](@ref)/[`GenericConstraintSlackDown`](@ref) for `gc` when
`PSI.get_use_slacks(model)`, one side per `get_sense(gc)` (`LE` → up only, `GE` → down only,
`EQ` → both), and merges each into [`NEMConstraintLHS`](@ref): `-slack_up` on the `LE` side,
`+slack_down` on the `GE` side, so `add_constraints!`'s stored bound becomes satisfiable by
relaxing it rather than infeasible. A no-op when `use_slacks` is `false`.
"""
function _add_gc_slack_variables!(
        container::PSI.OptimizationContainer, gc::GenericConstraint,
        model::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
    )
    PSI.get_use_slacks(model) || return
    name = PSY.get_name(gc)
    time_steps = PSI.get_time_steps(container)
    expr = PSI.get_expression(container, NEMConstraintLHS(), GenericConstraint, name)
    sense = get_sense(gc)
    jm = PSI.get_jump_model(container)

    if sense in (ConstraintSense.LE, ConstraintSense.EQ)
        slack = PSI.add_variable_container!(
            container, GenericConstraintSlackUp(), GenericConstraint, [name], time_steps; meta = name,
        )
        for t in time_steps
            slack[name, t] = JuMP.@variable(
                jm, base_name = "GenericConstraintSlackUp_{$name,$t}", lower_bound = 0.0,
            )
            JuMP.add_to_expression!(expr[name, t], -1.0, slack[name, t])
        end
    end
    if sense in (ConstraintSense.GE, ConstraintSense.EQ)
        slack = PSI.add_variable_container!(
            container, GenericConstraintSlackDown(), GenericConstraint, [name], time_steps; meta = name,
        )
        for t in time_steps
            slack[name, t] = JuMP.@variable(
                jm, base_name = "GenericConstraintSlackDown_{$name,$t}", lower_bound = 0.0,
            )
            JuMP.add_to_expression!(expr[name, t], 1.0, slack[name, t])
        end
    end
    return
end


# --- add_constraints!: sense dispatch, honouring the "invoked" series ---

"""
    _invoked_mask(container, gc, start_time = PSI.get_initial_time(container)) -> Vector{Float64}

The `GenericConstraint`'s `"invoked"` series (`1.0`/`0.0`) over the container's time steps from
`start_time`, read from the container's default forecast type.

# Returns
A `Vector{Float64}`.
"""
function _invoked_mask(
        container::PSI.OptimizationContainer, gc::GenericConstraint,
        start_time::DateTime = PSI.get_initial_time(container),
    )
    ts_type = PSI.get_default_time_series_type(container)
    forecast = IS.get_time_series(ts_type, gc, "invoked"; start_time = start_time, count = 1)
    return IS.get_time_series_values(
        gc, forecast; start_time = start_time, len = length(PSI.get_time_steps(container)),
        ignore_scaling_factors = true,
    )
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
    jm = PSI.get_jump_model(container)
    sense = get_sense(gc)
    slacks = PSI.get_use_slacks(model)
    slacks || !PSI.built_for_recurrent_solves(container) || throw(
        ArgumentError(
            "GenericConstraint \"$name\": a recurrent build masks non-invoked intervals with zero-cost " *
                "slacks, so its LinearFactorLimit model needs use_slacks = true.",
        ),
    )
    invoked = slacks ? nothing : _invoked_mask(container, gc)
    for t in time_steps
        if !slacks && invoked[t] == 0.0
            # PSI's dual read-back broadcasts over every cell, so a non-invoked interval keeps a
            # vacuous, disconnected row whose dual is exactly 0.0.
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
    _warn_absent_fcas_services(sys, gc)
    # Before add_constraints! reads NEMConstraintLHS: a slack must already be merged in for the
    # constraint it relaxes to be built with it, not around it.
    _add_gc_slack_variables!(container, gc, model)

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


"""
    PSI.objective_function!(container, gc, model::PSI.ServiceModel{GenericConstraint, LinearFactorLimit})

Prices `gc`'s elastic slacks (built by [`_add_gc_slack_variables!`](@ref), a no-op unless
`PSI.get_use_slacks(model)`) through a [`GenericConstraintSlackCostParameter`](@ref): each
interval's coefficient is its `"invoked"` value times `GENERICCONSTRAINTWEIGHT` times the Market
Price Cap per MW, so a non-invoked interval's slack is free and its row is vacuous.
`GenericConstraint`s built without slacks carry no cost of their own.

# Returns
`nothing`.
"""
function PSI.objective_function!(
        container::PSI.OptimizationContainer, gc::GenericConstraint,
        model::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
    )
    PSI.get_use_slacks(model) || return
    name = PSY.get_name(gc)
    time_steps = PSI.get_time_steps(container)
    resolution = PSI.get_resolution(container)
    initial_time = PSI.get_initial_time(container)
    base_power = PSI.get_base_power(container)
    weight = get_constraint_weight(gc)
    param = PSI.add_param_container!(
        container, GenericConstraintSlackCostParameter(), GenericConstraint,
        (GenericConstraintSlackUp, GenericConstraintSlackDown), PSI.SOSStatusVariable.NO_VARIABLE,
        false, Float64, [name], time_steps; meta = name,
    )
    invoked_values = PSI.get_parameter_array(param)
    penalties = PSI.get_multiplier_array(param)
    invoked = _invoked_mask(container, gc)
    _set_service_mpc_rate!(container, name, PSI.get_attribute(model, "market_price_cap"))
    for t in time_steps
        penalties[name, t] = base_power * interval_cost_coefficient(weight, resolution)
        invoked_values[name, t] = invoked[t]
        mpc = _service_market_price_cap(container, name, initial_time + resolution * (t - 1))
        _add_gc_slack_costs!(container, gc, invoked_values, penalties, t, mpc)
    end
    return
end


# Adds `gc`'s slacks at step `t` to the variant objective at `invoked x penalty` per unit; nothing
# when that is zero, which leaves the row vacuous.
function _add_gc_slack_costs!(container::PSI.OptimizationContainer, gc::GenericConstraint, invoked_values, penalties, t::Int, mpc::Real)
    name = PSY.get_name(gc)
    cost = invoked_values[name, t] * penalties[name, t] * mpc
    iszero(cost) && return
    for var_type in (GenericConstraintSlackUp, GenericConstraintSlackDown)
        PSI.has_container_key(container, var_type, GenericConstraint, name) || continue
        slack = PSI.get_variable(container, var_type(), GenericConstraint, name)
        PSI.add_to_objective_variant_expression!(container, cost * slack[name, t])
    end
    return
end


"""
    PSI.handle_variable_cost_parameter(::GenericConstraintSlackCostParameter, gc::GenericConstraint, name, parameter_array, parameter_multiplier, attributes, container, initial_forecast_time, horizon)

Simulation-step update of [`GenericConstraintSlackCostParameter`](@ref): reads `gc`'s `"invoked"`
values for the window starting at `initial_forecast_time` into `parameter_array` and re-adds the
slack costs (`invoked x` the build-time penalty in `parameter_multiplier`) to the variant objective.

# Returns
`nothing`.
"""
function PSI.handle_variable_cost_parameter(
        ::GenericConstraintSlackCostParameter, gc::GenericConstraint, name::String,
        parameter_array, parameter_multiplier, attributes, container::PSI.OptimizationContainer,
        initial_forecast_time::DateTime, horizon::Int,
    )
    invoked = _invoked_mask(container, gc, initial_forecast_time)
    resolution = PSI.get_resolution(container)
    for t in 1:horizon
        parameter_array[name, t] = invoked[t]
        mpc = _service_market_price_cap(container, name, initial_forecast_time + resolution * (t - 1))
        _add_gc_slack_costs!(container, gc, parameter_array, parameter_multiplier, t, mpc)
    end
    return
end


# Each key's long-format frame (`DateTime`, `value`): solved values, or realized ones of a simulation.
_read_dual_frames(results::PSI.OptimizationProblemResults, keys) = Dict(key => PSI.read_dual(results, key) for key in keys)
# Opens the simulation store once for all `keys`, over the window `read_realized_duals` reads.
function _read_dual_frames(results::PSI.SimulationProblemResults, keys)
    isempty(keys) && return Dict{PSI.OptimizationContainerKey, DataFrame}()
    vals = PSI.read_realized_duals(results, collect(keys))
    return Dict(key => vals[PSI.IS.Optimization.encode_key_as_string(key)] for key in keys)
end


"""
    compute_fcas_prices(results, sys; resolution = nothing) -> DataFrame

Maps solved [`NEMConstraintLimit`](@ref) duals onto regional FCAS prices: each `(region, service)`
`ROP` is the sum of the duals of every built [`GenericConstraint`](@ref) whose
[`get_fcas_requirements`](@ref) names that pair, in `\$/MWh`. This mirrors the sum of
`DISPATCH_FCAS_REQ`'s `MARGINALVALUE` (see [`read_fcas_prices`](@ref)). Duals keep the solver's
sign (change in cost per unit increase of the right-hand side): non-negative for a binding `>=`
constraint, non-positive for `<=`. Warns when a constraint with requirements has no recorded dual.

# Arguments
- `results`: `PSI.OptimizationProblemResults` of a model, or `PSI.SimulationProblemResults` of a
  simulation (its realized duals), that recorded `NEMConstraintLimit` duals.
- `sys`: the `System` the model was built from.
- `resolution`: interval length converting per-interval duals to `\$/MWh`. Defaults to the
  resolution the results record, which a single-interval solve does not; required then.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `REGIONID`, `BIDTYPE` and `ROP`, like [`read_fcas_prices`](@ref).
"""
function compute_fcas_prices(
        results::Union{PSI.OptimizationProblemResults, PSI.SimulationProblemResults}, sys::PSY.System;
        resolution::Union{Nothing, Dates.Period} = nothing,
    )
    resolution = something(resolution, PSI.get_resolution(results), Some(nothing))
    isnothing(resolution) && throw(
        ArgumentError(
            "compute_fcas_prices: `results` do not record a resolution (a single-interval model), so pass `resolution` explicitly.",
        ),
    )
    dual_keys = Dict(
        k.meta => k for k in PSI.list_dual_keys(results) if PSI.IS.Optimization.get_entry_type(k) === NEMConstraintLimit
    )
    scale = PSY.get_base_power(sys) * interval_hours(resolution)
    prices = Dict{Tuple{String, BidType}, DataFrame}()
    constrained = [gc for gc in PSY.get_components(GenericConstraint, sys) if !isempty(get_fcas_requirements(gc))]
    unrecorded = [PSY.get_name(gc) for gc in constrained if !haskey(dual_keys, PSY.get_name(gc))]
    recorded = [gc for gc in constrained if haskey(dual_keys, PSY.get_name(gc))]
    duals = _read_dual_frames(results, [dual_keys[PSY.get_name(gc)] for gc in recorded])
    for gc in recorded
        dual = duals[dual_keys[PSY.get_name(gc)]]
        for req in get_fcas_requirements(gc)
            id = (get_region(req), get_service(req))
            term = DataFrame(; SETTLEMENTDATE = dual.DateTime, ROP = dual.value ./ scale)
            haskey(prices, id) ? (prices[id].ROP .+= term.ROP) : (prices[id] = term)
        end
    end
    isempty(unrecorded) || @warn(
        "compute_fcas_prices: $(length(unrecorded)) GenericConstraint(s) with FCAS requirements " *
            "have no NEMConstraintLimit dual and are left out: $(join(first(sort!(unrecorded), 5), ", "))" *
            (length(unrecorded) > 5 ? ", ..." : ".")
    )
    out = DataFrame(; SETTLEMENTDATE = DateTime[], REGIONID = String[], BIDTYPE = BidType[], ROP = Float64[])
    for ((region, service), df) in sort!(collect(prices); by = p -> (p[1][1], string(p[1][2])))
        append!(out, DataFrame(; SETTLEMENTDATE = df.SETTLEMENTDATE, REGIONID = region, BIDTYPE = service, ROP = df.ROP))
    end
    return out
end
