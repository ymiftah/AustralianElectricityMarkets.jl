PSI.get_default_time_series_names(::Type{FCASService}, ::Type{FCASMarket}) =
    Dict{Type{<:PSI.TimeSeriesParameter}, String}()

PSI.get_default_attributes(::Type{FCASService}, ::Type{FCASMarket}) = Dict{String, Any}()

_is_regulation_service(bid_type::BidType) = bid_type in FCAS_REGULATION_MARKETS

"""
    _fcas_direction(device, bid_type) -> Bool

Whether `device` carries `bid_type`'s FCAS series decrementally (the storage `LOAD`-side bid)
rather than incrementally. Throws `ArgumentError` if neither series is attached, or if both are
(bidirectional FCAS capacity is not modeled).

# Returns
`true` for a decremental-only device, `false` for an incremental-only device.
"""
function _fcas_direction(device, bid_type::BidType)
    bid_type_str = string(bid_type)
    has_inc = PSY.has_time_series(device, PSY.Deterministic, "fcas_trapezium_$bid_type_str")
    has_dec = PSY.has_time_series(device, PSY.Deterministic, "fcas_trapezium_$(bid_type_str)_decremental")
    has_inc && has_dec && throw(
        ArgumentError(
            "FCASMarket: \"$(PSY.get_name(device))\" carries both an incremental and a " *
                "decremental $bid_type_str bid; bidirectional FCAS capacity is not modeled.",
        ),
    )
    has_inc && return false
    has_dec && return true
    throw(
        ArgumentError(
            "FCASMarket: \"$(PSY.get_name(device))\" carries neither an incremental nor a " *
                "decremental $bid_type_str trapezium series - call set_fcas_bids! first.",
        ),
    )
end

"""
    _fcas_energy_terms(device, is_regulation, decremental) -> Vector{Tuple{DataType, Float64}}

The `PSI.VariableType`s (and their sign) making up `device`'s FCAS "Energy Dispatch Target": for a
`PSY.Storage` device, the bid side's own energy on regulation (`ActivePowerOutVariable` for a
generation-side bid, `-ActivePowerInVariable` for a load-side one) and the net
`ActivePowerOutVariable - ActivePowerInVariable` on contingency; `ActivePowerVariable` otherwise.
Throws `ArgumentError` for a decremental (`LOAD`-direction) bid on a non-`Storage` device.

# Returns
`Vector{Tuple{DataType, Float64}}` of `(VariableType, multiplier)` pairs.
"""
function _fcas_energy_terms(device::PSY.Device, is_regulation::Bool, decremental::Bool)
    if device isa PSY.Storage
        is_regulation || return [(PSI.ActivePowerOutVariable, 1.0), (PSI.ActivePowerInVariable, -1.0)]
        return decremental ? [(PSI.ActivePowerInVariable, -1.0)] : [(PSI.ActivePowerOutVariable, 1.0)]
    end
    decremental && throw(
        ArgumentError(
            "FCASMarket: \"$(PSY.get_name(device))\" ($(typeof(device))) has a decremental FCAS " *
                "bid but is not a `PSY.Storage` device; scheduled-load FCAS capacity is not modeled.",
        ),
    )
    return [(PSI.ActivePowerVariable, 1.0)]
end

"""
    _add_fcas_energy_terms!(container, expr, device, is_regulation, decremental, dname, t)

Adds `device`'s FCAS energy terms ([`_fcas_energy_terms`](@ref)) into `expr` at `(dname, t)`.
Throws `ArgumentError` if `device`'s formulation defines no such energy variable.
"""
function _add_fcas_energy_terms!(
        container, expr, device::PSY.Device, is_regulation::Bool, decremental::Bool, dname::AbstractString, t::Int,
    )
    for (var_type, multiplier) in _fcas_energy_terms(device, is_regulation, decremental)
        PSI.has_container_key(container, var_type, typeof(device)) || throw(
            ArgumentError(
                "FCASMarket: \"$dname\" ($(typeof(device))) contributes to an FCASService, but its " *
                    "device formulation defines no $(nameof(var_type)) for the FCAS energy term.",
            ),
        )
        var = PSI.get_variable(container, var_type(), typeof(device))
        JuMP.add_to_expression!(expr, multiplier, var[dname, t])
    end
    return
end

"""
    _fcas_series(container, device, bid_type, decremental) -> (trapeziums, curves)

`device`'s FCAS trapezium and offer-curve series for `bid_type`, one entry per
`PSI.get_time_steps(container)`, read via
[`get_scaled_fcas_trapezium`](@ref)/[`get_fcas_offer_curve`](@ref). The trapezium is AEMO
*FCAS Model in NEMDE* §4's scaled/effective trapezium wherever `device` carries the scaling
input series ([`set_fcas_scaling_inputs!`](@ref)); otherwise it is the bid trapezium unscaled.

# Returns
`(trapeziums::Vector{FCASTrapezium}, curves::Vector{PSY.PiecewiseStepData})`.
"""
function _fcas_series(container::PSI.OptimizationContainer, device, bid_type::BidType, decremental::Bool)
    initial_time = PSI.get_initial_time(container)
    horizon = length(PSI.get_time_steps(container))
    trapeziums = get_scaled_fcas_trapezium(device, bid_type, initial_time, horizon; decremental = decremental)
    curves = get_fcas_offer_curve(device, bid_type, initial_time, horizon; decremental = decremental)
    return trapeziums, curves
end

"""
    _fcas_sign_ok(device, is_regulation, decremental, trap) -> Bool

AEMO *FCAS Model in NEMDE* §5's `EnablementMax`/`EnablementMin` sign pre-condition:
non-`PSY.Storage` devices, and generation-side (incremental) regulation on a `PSY.Storage`
device, require `EnablementMax >= 0`; load-side (decremental) regulation on a `PSY.Storage`
device requires `EnablementMin <= 0`; contingency FCAS on a `PSY.Storage` device carries no sign
requirement.

# Returns
`Bool`.
"""
function _fcas_sign_ok(device::PSY.Device, is_regulation::Bool, decremental::Bool, trap::FCASTrapezium)
    if device isa PSY.Storage
        is_regulation || return true
        return decremental ? get_enablement_min(trap) <= 0.0 : get_enablement_max(trap) >= 0.0
    end
    return get_enablement_max(trap) >= 0.0
end

"""
    _fcas_energy_max_avail_ok(device, is_regulation, decremental, trap, energy_max_avail) -> Bool

AEMO §5's "energy maximum availability" pre-condition: a device's energy availability must
leave the FCAS trapezium reachable. For a non-`PSY.Storage` device, `energy_max_avail >=
EnablementMin` (skipped when `energy_max_avail` is unknown). For a `PSY.Storage` device,
`energy_max_avail` is `(gen = ..., load = ...)`, each direction's energy bid `MAXAVAIL`
([`get_storage_energy_max_avail`](@ref)), falling back to the device's static output/input
ratings when `nothing`: load-side (decremental) regulation requires `-load <= EnablementMax`,
generation-side regulation requires `gen >= EnablementMin`, and contingency FCAS requires both.

# Returns
`Bool`.
"""
function _fcas_energy_max_avail_ok(
        device::PSY.Device, is_regulation::Bool, decremental::Bool, trap::FCASTrapezium,
        energy_max_avail::Union{Nothing, Float64, NamedTuple{(:gen, :load), Tuple{Float64, Float64}}},
    )
    if device isa PSY.Storage
        gen_max, load_max = if isnothing(energy_max_avail)
            PSY.get_output_active_power_limits(device).max, PSY.get_input_active_power_limits(device).max
        else
            energy_max_avail.gen, energy_max_avail.load
        end
        load_ok = -load_max <= get_enablement_max(trap)
        gen_ok = gen_max >= get_enablement_min(trap)
        is_regulation && return decremental ? load_ok : gen_ok
        return load_ok && gen_ok
    end
    isnothing(energy_max_avail) && return true
    return energy_max_avail >= get_enablement_min(trap)
end

"""
    _fcas_enabled(device, is_regulation, decremental, trap, curve, energy_max_avail, initial_mw) -> Bool

The computable subset of AEMO's *FCAS Model in NEMDE* §5 enablement pre-conditions: `MaxAvail`
positive; at least one priced band with positive quantity; `EnablementMax` at or above
`EnablementMin`; the sign pre-condition ([`_fcas_sign_ok`](@ref)); the energy-maximum-availability
pre-condition ([`_fcas_energy_max_avail_ok`](@ref)); and, when `initial_mw` is known, the
"stranded" pre-condition: `initial_mw` (net, for a `PSY.Storage` device) or `Max[initial_mw, 0]`
(otherwise) inside `[EnablementMin, EnablementMax]`. The AGC-status and daily/profiled-energy
pre-conditions are not checked.

# Returns
`Bool`.
"""
function _fcas_enabled(
        device::PSY.Device, is_regulation::Bool, decremental::Bool, trap::FCASTrapezium,
        curve::PSY.PiecewiseStepData,
        energy_max_avail::Union{Nothing, Float64, NamedTuple{(:gen, :load), Tuple{Float64, Float64}}},
        initial_mw::Union{Nothing, Float64},
    )
    get_max_avail(trap) > 0.0 || return false
    any(>(0.0), diff(PSY.get_x_coords(curve))) || return false
    get_enablement_max(trap) >= get_enablement_min(trap) || return false
    _fcas_sign_ok(device, is_regulation, decremental, trap) || return false
    _fcas_energy_max_avail_ok(device, is_regulation, decremental, trap, energy_max_avail) || return false
    if !isnothing(initial_mw)
        point = device isa PSY.Storage ? initial_mw : max(initial_mw, 0.0)
        get_enablement_min(trap) <= point <= get_enablement_max(trap) || return false
    end
    return true
end

"""
    _fcas_initial_mw_first_interval_only(devices_template, device) -> Bool

Whether `device`'s dispatch model is [`NEMLookaheadDispatch`](@ref), whose later intervals start
from the model's own dispatch rather than a metered `INITIALMW`.

# Returns
`Bool`.
"""
function _fcas_initial_mw_first_interval_only(devices_template, device::PSY.Device)
    for model in values(devices_template)
        PSI.get_component_type(model) == typeof(device) || continue
        return PSI.get_formulation(model) <: NEMLookaheadDispatch
    end
    return false
end

"""
    _fcas_enabled_mask(container, devices_template, device, bid_type, decremental) -> Vector{Bool}

Per-interval [`_fcas_enabled`](@ref) for `device`'s `bid_type` bid, with `InitialMW` from
[`get_initial_mw`](@ref) (first interval only under [`NEMLookaheadDispatch`](@ref)) and energy
availability from [`get_energy_availability`](@ref), or [`get_storage_energy_max_avail`](@ref)
for a `PSY.Storage` device.

# Returns
`Vector{Bool}`, one entry per `PSI.get_time_steps(container)`.
"""
function _fcas_enabled_mask(
        container::PSI.OptimizationContainer, devices_template, device::PSY.Device, bid_type::BidType, decremental::Bool,
    )
    is_regulation = _is_regulation_service(bid_type)
    initial_time = PSI.get_initial_time(container)
    time_steps = PSI.get_time_steps(container)
    horizon = length(time_steps)
    trapeziums, curves = _fcas_series(container, device, bid_type, decremental)
    initial_mw = get_initial_mw(device, initial_time, horizon)
    first_only = _fcas_initial_mw_first_interval_only(devices_template, device)
    availability = if device isa PSY.Storage
        get_storage_energy_max_avail(device, initial_time, horizon)
    else
        get_energy_availability(device, initial_time, horizon)
    end
    return map(time_steps) do t
        init = (isnothing(initial_mw) || (first_only && t > 1)) ? nothing : initial_mw[t]
        avail = if isnothing(availability)
            nothing
        elseif device isa PSY.Storage
            (gen = availability.gen[t], load = availability.load[t])
        else
            availability[t]
        end
        _fcas_enabled(device, is_regulation, decremental, trapeziums[t], curves[t], avail, init)
    end
end

"""
    _device_regulation_var(container, device, reg_bid_type, t) -> Union{Nothing, JuMP.VariableRef}

`device`'s [`FCASCapacityVariable`](@ref) at `t` for the `reg_bid_type` regulation market it
belongs to, found via `PSY.get_services(device)`. `nothing` when `device` carries no such
service, or that service wasn't built under [`FCASMarket`](@ref) this run. Throws
`ArgumentError` if `device` belongs to more than one such service.

# Returns
`Union{Nothing, JuMP.VariableRef}`.
"""
function _device_regulation_var(container::PSI.OptimizationContainer, device::PSY.Device, reg_bid_type::BidType, t::Int)
    dname = PSY.get_name(device)
    found = JuMP.VariableRef[]
    for svc in PSY.get_services(device)
        svc isa FCASService || continue
        get_bid_type(svc) == reg_bid_type || continue
        name = PSY.get_name(svc)
        PSI.has_container_key(container, FCASCapacityVariable, FCASService, name) || continue
        var = PSI.get_variable(container, FCASCapacityVariable(), FCASService, name)
        dname in axes(var, 1) || continue
        push!(found, var[dname, t])
    end
    length(found) > 1 && throw(
        ArgumentError(
            "FCASMarket: \"$dname\" contributes to $(length(found)) $(string(reg_bid_type)) " *
                "FCASServices; a device can offer each FCAS market through only one.",
        ),
    )
    return isempty(found) ? nothing : only(found)
end

function PSI.construct_service!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ArgumentConstructStage,
        model::PSI.ServiceModel{FCASService, FCASMarket},
        devices_template::Dict{Symbol, PSI.DeviceModel},
        incompatible_device_types::Set{<:DataType},
        network_model::PSI.NetworkModel,
    )
    PSI.built_for_recurrent_solves(container) && throw(
        ArgumentError(
            "FCASMarket supports a standalone `DecisionModel` only: FCAS bids and the §5 " *
                "enablement pre-conditions are read once at build, so a `Simulation` would solve " *
                "every later step with the first step's FCAS data.",
        ),
    )
    unsupported = filter(!=(FCASJointCapacityConstraint), PSI.get_duals(model))
    isempty(unsupported) || throw(
        ArgumentError(
            "FCASMarket records duals for FCASJointCapacityConstraint only; got $(unsupported).",
        ),
    )
    name = PSI.get_service_name(model)
    svc = PSY.get_component(FCASService, sys, name)
    PSY.get_available(svc) || return
    devices = PSI.get_contributing_devices(model)
    isempty(devices) && return
    bid_type = get_bid_type(svc)
    is_regulation = _is_regulation_service(bid_type)
    time_steps = PSI.get_time_steps(container)
    names = PSY.get_name.(devices)

    var = PSI.add_variable_container!(
        container, FCASCapacityVariable(), FCASService, names, time_steps; meta = name,
    )
    upper_lhs = PSI.lazy_container_addition!(
        container, FCASJointCapacityLHS(), FCASService, names, time_steps; meta = "$(name)_upper",
    )
    lower_lhs = PSI.lazy_container_addition!(
        container, FCASJointCapacityLHS(), FCASService, names, time_steps; meta = "$(name)_lower",
    )
    jm = PSI.get_jump_model(container)

    for device in devices
        dname = PSY.get_name(device)
        decremental = _fcas_direction(device, bid_type)
        trapeziums, _ = _fcas_series(container, device, bid_type, decremental)
        enabled = _fcas_enabled_mask(container, devices_template, device, bid_type, decremental)
        for t in time_steps
            trap = trapeziums[t]
            var[dname, t] = JuMP.@variable(
                jm, base_name = "FCASCapacityVariable_FCASService_$(name)_{$dname, $t}", lower_bound = 0.0,
            )
            JuMP.set_upper_bound(var[dname, t], enabled[t] ? get_max_avail(trap) : 0.0)

            _add_fcas_energy_terms!(container, upper_lhs[dname, t], device, is_regulation, decremental, dname, t)
            JuMP.add_to_expression!(upper_lhs[dname, t], get_upper_slope_coeff(trap), var[dname, t])
            _add_fcas_energy_terms!(container, lower_lhs[dname, t], device, is_regulation, decremental, dname, t)
            JuMP.add_to_expression!(lower_lhs[dname, t], -get_lower_slope_coeff(trap), var[dname, t])
        end
    end
    return
end

"""
    _add_fcas_offer_cost!(container, service_name, dname, t, capacity_var, curve)

Adds `capacity_var`'s offer cost under `curve` (a `PSY.PiecewiseStepData` of cumulative-MW
bands with non-decreasing per-band prices) to the objective, via one bounded band variable per
band summing to `capacity_var`. Band quantities are per-unit of the system base and prices are
`\$/MW` per hour, so each coefficient is scaled by `PSI.get_base_power(container)` and the
container's resolution in hours.

# Returns
`nothing`.
"""
function _add_fcas_offer_cost!(
        container::PSI.OptimizationContainer, service_name::AbstractString, dname::AbstractString, t::Int,
        capacity_var, curve::PSY.PiecewiseStepData,
    )
    x = PSY.get_x_coords(curve)
    y = PSY.get_y_coords(curve)
    n_bands = length(y)
    n_bands == 0 && return
    base_power = PSI.get_base_power(container)
    resolution = PSI.get_resolution(container)
    jm = PSI.get_jump_model(container)
    bands = JuMP.@variable(
        jm, [i = 1:n_bands], base_name = "FCASOfferBandVariable_$(service_name)_{$dname, $t}",
        lower_bound = 0.0, upper_bound = x[i + 1] - x[i],
    )
    JuMP.@constraint(jm, sum(bands) == capacity_var)
    cost = base_power * sum(interval_cost_coefficient(y[i], resolution) * bands[i] for i in 1:n_bands)
    PSI.add_to_objective_invariant_expression!(container, cost)
    return
end

"""
    PSI.objective_function!(container, svc, model::PSI.ServiceModel{FCASService, FCASMarket})

Adds every contributing device's [`_add_fcas_offer_cost!`](@ref) epigraph cost to the objective.

# Returns
`nothing`.
"""
function PSI.objective_function!(
        container::PSI.OptimizationContainer,
        svc::FCASService,
        model::PSI.ServiceModel{FCASService, FCASMarket},
    )
    name = PSY.get_name(svc)
    devices = PSI.get_contributing_devices(model)
    isempty(devices) && return
    bid_type = get_bid_type(svc)
    time_steps = PSI.get_time_steps(container)
    fcas_var = PSI.get_variable(container, FCASCapacityVariable(), FCASService, name)
    for device in devices
        dname = PSY.get_name(device)
        decremental = _fcas_direction(device, bid_type)
        _, curves = _fcas_series(container, device, bid_type, decremental)
        for t in time_steps
            _add_fcas_offer_cost!(container, name, dname, t, fcas_var[dname, t], curves[t])
        end
    end
    return
end

function PSI.construct_service!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ModelConstructStage,
        model::PSI.ServiceModel{FCASService, FCASMarket},
        devices_template::Dict{Symbol, PSI.DeviceModel},
        incompatible_device_types::Set{<:DataType},
        network_model::PSI.NetworkModel,
    )
    name = PSI.get_service_name(model)
    svc = PSY.get_component(FCASService, sys, name)
    PSY.get_available(svc) || return
    devices = PSI.get_contributing_devices(model)
    isempty(devices) && return
    bid_type = get_bid_type(svc)
    is_regulation = _is_regulation_service(bid_type)
    time_steps = PSI.get_time_steps(container)
    names = PSY.get_name.(devices)
    jm = PSI.get_jump_model(container)

    upper_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_upper")
    lower_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_lower")

    # Contingency services carry the regulation targets: `RaiseReg` upper, `LowerReg` lower.
    if !is_regulation
        for device in devices
            dname = PSY.get_name(device)
            for t in time_steps
                raise_reg = _device_regulation_var(container, device, BidType.RAISEREG, t)
                isnothing(raise_reg) || JuMP.add_to_expression!(upper_lhs[dname, t], 1.0, raise_reg)
                lower_reg = _device_regulation_var(container, device, BidType.LOWERREG, t)
                isnothing(lower_reg) || JuMP.add_to_expression!(lower_lhs[dname, t], -1.0, lower_reg)
            end
        end
    end

    con_upper = PSI.add_constraints_container!(
        container, FCASJointCapacityConstraint(), FCASService, names, time_steps; meta = "$(name)_upper",
    )
    con_lower = PSI.add_constraints_container!(
        container, FCASJointCapacityConstraint(), FCASService, names, time_steps; meta = "$(name)_lower",
    )
    for device in devices
        dname = PSY.get_name(device)
        decremental = _fcas_direction(device, bid_type)
        trapeziums, _ = _fcas_series(container, device, bid_type, decremental)
        enabled = _fcas_enabled_mask(container, devices_template, device, bid_type, decremental)
        for t in time_steps
            if !enabled[t]
                con_upper[dname, t] = JuMP.@constraint(jm, 0.0 <= 1.0)
                con_lower[dname, t] = JuMP.@constraint(jm, 0.0 <= 1.0)
                continue
            end
            trap = trapeziums[t]
            con_upper[dname, t] = JuMP.@constraint(jm, upper_lhs[dname, t] <= get_enablement_max(trap))
            con_lower[dname, t] = JuMP.@constraint(jm, lower_lhs[dname, t] >= get_enablement_min(trap))
        end
    end

    if FCASJointCapacityConstraint in PSI.get_duals(model)
        for side in ("upper", "lower")
            PSI.add_dual_container!(
                container, FCASJointCapacityConstraint, FCASService, names, time_steps; meta = "$(name)_$side",
            )
        end
    end

    PSI.objective_function!(container, svc, model)
    return
end
