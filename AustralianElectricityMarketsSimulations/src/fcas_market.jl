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
    _fcas_energy_terms(device, decremental) -> Vector{Tuple{DataType, Float64}}

The `PSI.VariableType`s (and their sign) making up `device`'s FCAS "Energy Dispatch Target": the
net `ActivePowerOutVariable - ActivePowerInVariable` for a `PSY.Storage` device, or
`ActivePowerVariable` otherwise. Throws `ArgumentError` for a decremental (`LOAD`-direction) bid
on a non-`Storage` device.

# Returns
`Vector{Tuple{DataType, Float64}}` of `(VariableType, multiplier)` pairs.
"""
function _fcas_energy_terms(device::PSY.Device, decremental::Bool)
    device isa PSY.Storage && return [(PSI.ActivePowerOutVariable, 1.0), (PSI.ActivePowerInVariable, -1.0)]
    decremental && throw(
        ArgumentError(
            "FCASMarket: \"$(PSY.get_name(device))\" ($(typeof(device))) has a decremental FCAS " *
                "bid but is not a `PSY.Storage` device; scheduled-load FCAS capacity is not modeled.",
        ),
    )
    return [(PSI.ActivePowerVariable, 1.0)]
end

"Adds `device`'s FCAS energy terms ([`_fcas_energy_terms`](@ref)) into `expr` at `(dname, t)`."
function _add_fcas_energy_terms!(container, expr, device::PSY.Device, decremental::Bool, dname::AbstractString, t::Int)
    for (var_type, multiplier) in _fcas_energy_terms(device, decremental)
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
    _fcas_ts_value_accessor(container, ::Type{P}, ::Type{T}) -> Union{Nothing, Function}

An `(name, t) -> Float64` reader of `T`'s `P` time-series parameter, or `nothing` when `T`
carries no such parameter in `container`.

# Returns
`Union{Nothing, Function}`.
"""
function _fcas_ts_value_accessor(container::PSI.OptimizationContainer, ::Type{P}, ::Type{T}) where {P <: PSI.TimeSeriesParameter, T}
    PSI.has_container_key(container, P, T) || return nothing
    accessor, _ = _ts_parameter_accessor(container, P, T)
    return (name, t) -> JuMP.value(accessor(name, t))
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
    _fcas_energy_max_avail_ok(device, trap, energy_max_avail) -> Bool

AEMO §5's "energy maximum availability" pre-condition: a device's own dispatch ceiling must
leave the FCAS trapezium reachable. For a non-`PSY.Storage` device, `energy_max_avail >=
EnablementMin` (skipped when `energy_max_avail` is unknown). For a `PSY.Storage` device, its
static output/input ratings must satisfy `-InputActivePowerLimit.max <= EnablementMax` and
`OutputActivePowerLimit.max >= EnablementMin`.

# Returns
`Bool`.
"""
function _fcas_energy_max_avail_ok(device::PSY.Device, trap::FCASTrapezium, energy_max_avail::Union{Nothing, Float64})
    if device isa PSY.Storage
        gen_max = PSY.get_output_active_power_limits(device).max
        load_max = PSY.get_input_active_power_limits(device).max
        return -load_max <= get_enablement_max(trap) && gen_max >= get_enablement_min(trap)
    end
    isnothing(energy_max_avail) && return true
    return energy_max_avail >= get_enablement_min(trap)
end

"""
    _fcas_enabled(device, is_regulation, decremental, trap, curve, energy_max_avail, initial_mw) -> Bool

The computable subset of AEMO's *FCAS Model in NEMDE* §5 enablement pre-conditions: `MaxAvail`
positive; at least one priced band with positive quantity; `EnablementMax` at or above
`EnablementMin`; the sign pre-condition ([`_fcas_sign_ok`](@ref)); the energy-maximum-availability
pre-condition ([`_fcas_energy_max_avail_ok`](@ref)); and, when `initial_mw` is known, `Max[
InitialMW, 0]` inside `[EnablementMin, EnablementMax]` (the "stranded" pre-condition, checked only
for a non-`PSY.Storage` device, where an initial-MW series is available). The AGC-status and
daily/profiled-energy pre-conditions are not checked - they read data this package does not have.

# Returns
`Bool`.
"""
function _fcas_enabled(
        device::PSY.Device, is_regulation::Bool, decremental::Bool, trap::FCASTrapezium,
        curve::PSY.PiecewiseStepData, energy_max_avail::Union{Nothing, Float64}, initial_mw::Union{Nothing, Float64},
    )
    get_max_avail(trap) > 0.0 || return false
    any(>(0.0), diff(PSY.get_x_coords(curve))) || return false
    get_enablement_max(trap) >= get_enablement_min(trap) || return false
    _fcas_sign_ok(device, is_regulation, decremental, trap) || return false
    _fcas_energy_max_avail_ok(device, trap, energy_max_avail) || return false
    if !(device isa PSY.Storage) && !isnothing(initial_mw)
        get_enablement_min(trap) <= max(initial_mw, 0.0) <= get_enablement_max(trap) || return false
    end
    return true
end

"""
    _device_regulation_var(container, device, reg_bid_type, t) -> Union{Nothing, JuMP.VariableRef}

`device`'s [`FCASCapacityVariable`](@ref) at `t` for the `reg_bid_type` regulation market it
belongs to, found via `PSY.get_services(device)`. `nothing` when `device` carries no such service, or that service wasn't built under
[`FCASMarket`](@ref) this run.

# Returns
`Union{Nothing, JuMP.VariableRef}`.
"""
function _device_regulation_var(container::PSI.OptimizationContainer, device::PSY.Device, reg_bid_type::BidType, t::Int)
    for svc in PSY.get_services(device)
        svc isa FCASService || continue
        get_bid_type(svc) == reg_bid_type || continue
        name = PSY.get_name(svc)
        PSI.has_container_key(container, FCASCapacityVariable, FCASService, name) || continue
        var = PSI.get_variable(container, FCASCapacityVariable(), FCASService, name)
        dname = PSY.get_name(device)
        dname in axes(var, 1) || continue
        return var[dname, t]
    end
    return nothing
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
        trapeziums, curves = _fcas_series(container, device, bid_type, decremental)
        is_storage = device isa PSY.Storage
        initial_mw_at = is_storage ? nothing : _fcas_ts_value_accessor(container, InitialPowerTimeSeriesParameter, typeof(device))
        energy_max_avail_at = is_storage ? nothing : _fcas_ts_value_accessor(container, PSI.ActivePowerTimeSeriesParameter, typeof(device))
        for t in time_steps
            trap = trapeziums[t]
            initial_mw = isnothing(initial_mw_at) ? nothing : initial_mw_at(dname, t)
            energy_max_avail = isnothing(energy_max_avail_at) ? nothing : energy_max_avail_at(dname, t)
            enabled = _fcas_enabled(device, is_regulation, decremental, trap, curves[t], energy_max_avail, initial_mw)

            var[dname, t] = JuMP.@variable(
                jm, base_name = "FCASCapacityVariable_FCASService_$(name)_{$dname, $t}", lower_bound = 0.0,
            )
            JuMP.set_upper_bound(var[dname, t], enabled ? max(get_max_avail(trap), 0.0) : 0.0)

            _add_fcas_energy_terms!(container, upper_lhs[dname, t], device, decremental, dname, t)
            JuMP.add_to_expression!(upper_lhs[dname, t], get_upper_slope_coeff(trap), var[dname, t])
            _add_fcas_energy_terms!(container, lower_lhs[dname, t], device, decremental, dname, t)
            JuMP.add_to_expression!(lower_lhs[dname, t], -get_lower_slope_coeff(trap), var[dname, t])
        end
    end
    return
end

"""
    _add_fcas_offer_cost!(container, dname, t, capacity_var, curve)

Adds `capacity_var`'s offer cost under `curve` (a `PSY.PiecewiseStepData` of cumulative-MW
bands with non-decreasing per-band prices) to the objective, via one bounded band variable per
band summing to `capacity_var`. Band quantities are per-unit of the system base and prices are
`\$/MW`, so each coefficient is scaled by `PSI.get_base_power(container)`.

# Returns
`nothing`.
"""
function _add_fcas_offer_cost!(
        container::PSI.OptimizationContainer, dname::AbstractString, t::Int, capacity_var, curve::PSY.PiecewiseStepData,
    )
    x = PSY.get_x_coords(curve)
    y = PSY.get_y_coords(curve)
    n_bands = length(y)
    n_bands == 0 && return
    base_power = PSI.get_base_power(container)
    jm = PSI.get_jump_model(container)
    bands = JuMP.@variable(
        jm, [i = 1:n_bands], base_name = "FCASOfferBandVariable_$(dname)_{$t}",
        lower_bound = 0.0, upper_bound = x[i + 1] - x[i],
    )
    JuMP.@constraint(jm, sum(bands) == capacity_var)
    cost = base_power * sum(interval_cost_coefficient(y[i]) * bands[i] for i in 1:n_bands)
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
            _add_fcas_offer_cost!(container, dname, t, fcas_var[dname, t], curves[t])
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
    fcas_var = PSI.get_variable(container, FCASCapacityVariable(), FCASService, name)

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
        for t in time_steps
            # A zero upper bound marks a (device, t) not enabled for this service.
            if JuMP.upper_bound(fcas_var[dname, t]) <= 0.0
                con_upper[dname, t] = JuMP.@constraint(jm, 0.0 <= 1.0)
                con_lower[dname, t] = JuMP.@constraint(jm, 0.0 <= 1.0)
                continue
            end
            trap = trapeziums[t]
            con_upper[dname, t] = JuMP.@constraint(jm, upper_lhs[dname, t] <= get_enablement_max(trap))
            con_lower[dname, t] = JuMP.@constraint(jm, lower_lhs[dname, t] >= get_enablement_min(trap))
        end
    end

    if !isempty(PSI.get_duals(model))
        for constraint_type in PSI.get_duals(model)
            PSI.add_dual_container!(
                container, constraint_type, FCASService, names, time_steps; meta = "$(name)_upper",
            )
            PSI.add_dual_container!(
                container, constraint_type, FCASService, names, time_steps; meta = "$(name)_lower",
            )
        end
    end

    PSI.objective_function!(container, svc, model)
    return
end
