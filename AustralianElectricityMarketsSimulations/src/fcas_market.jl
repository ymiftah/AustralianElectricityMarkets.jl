PSI.get_default_time_series_names(::Type{FCASService}, ::Type{FCASMarket}) =
    Dict{Type{<:PSI.TimeSeriesParameter}, String}()

PSI.get_default_attributes(::Type{FCASService}, ::Type{FCASMarket}) = Dict{String, Any}()

_is_regulation_service(bid_type::BidType) = bid_type in FCAS_REGULATION_MARKETS

"""
    _fcas_direction(device, bid_type) -> Symbol

Which of `bid_type`'s `"fcas_trapezium_<bid_type>[_decremental]"` series `device` carries.
Throws `ArgumentError` if neither series is attached, or if both are attached on a device other
than a `PSY.Storage` regulation bid (bidirectional FCAS capacity is modeled only for a
`PSY.Storage` device's generation-side and load-side regulation bids).

# Returns
`:incremental`, `:decremental`, or `:both`.
"""
function _fcas_direction(device, bid_type::BidType)
    bid_type_str = string(bid_type)
    has_inc = PSY.has_time_series(device, PSY.Deterministic, "fcas_trapezium_$bid_type_str")
    has_dec = PSY.has_time_series(device, PSY.Deterministic, "fcas_trapezium_$(bid_type_str)_decremental")
    if has_inc && has_dec
        device isa PSY.Storage && _is_regulation_service(bid_type) && return :both
        throw(
            ArgumentError(
                "FCASMarket: \"$(PSY.get_name(device))\" carries both an incremental and a " *
                    "decremental $bid_type_str bid; bidirectional FCAS capacity is modeled only " *
                    "for a `PSY.Storage` device's regulation markets.",
            ),
        )
    end
    has_inc && return :incremental
    has_dec && return :decremental
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
    _fcas_side_energy_terms(side) -> Vector{Tuple{DataType, Float64}}

The `PSI.VariableType` (and its sign) making up one side of a `PSY.Storage` device's FCAS
"Energy Dispatch Target": `ActivePowerOutVariable` for `:gen`, `-ActivePowerInVariable` for
`:load`.

# Returns
`Vector{Tuple{DataType, Float64}}` of `(VariableType, multiplier)` pairs.
"""
function _fcas_side_energy_terms(side::Symbol)
    side === :gen && return [(PSI.ActivePowerOutVariable, 1.0)]
    side === :load && return [(PSI.ActivePowerInVariable, -1.0)]
    throw(ArgumentError("side must be :gen or :load, got $(repr(side))"))
end

"Adds `device`'s one-side FCAS energy term ([`_fcas_side_energy_terms`](@ref)) into `expr` at `(dname, t)`."
function _add_fcas_side_energy_terms!(container, expr, device::PSY.Device, side::Symbol, dname::AbstractString, t::Int)
    for (var_type, multiplier) in _fcas_side_energy_terms(side)
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
    _fcas_regulation_sides(container, device, bid_type) -> (gen_trapeziums, gen_curves, load_trapeziums, load_curves)

A `PSY.Storage` device's generation-side and load-side trapezium and offer-curve series
([`_fcas_series`](@ref)) for a regulation `bid_type` it bids on both sides.

# Returns
`(gen_trapeziums::Vector{FCASTrapezium}, gen_curves::Vector{PSY.PiecewiseStepData}, load_trapeziums::Vector{FCASTrapezium}, load_curves::Vector{PSY.PiecewiseStepData})`.
"""
function _fcas_regulation_sides(container::PSI.OptimizationContainer, device, bid_type::BidType)
    gen_trapeziums, gen_curves = _fcas_series(container, device, bid_type, false)
    load_trapeziums, load_curves = _fcas_series(container, device, bid_type, true)
    return gen_trapeziums, gen_curves, load_trapeziums, load_curves
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
    _fcas_enabled(device, is_regulation, decremental, trap, curve, energy_max_avail, initial_mw, agc_status; check_stranded = true) -> Bool

The computable subset of AEMO's *FCAS Model in NEMDE* §5 enablement pre-conditions: `MaxAvail`
positive; at least one priced band with positive quantity; `EnablementMax` at or above
`EnablementMin`; the sign pre-condition ([`_fcas_sign_ok`](@ref)); the energy-maximum-availability
pre-condition ([`_fcas_energy_max_avail_ok`](@ref)); when `check_stranded` and `initial_mw` is
known, the "stranded" pre-condition (`initial_mw` for a `PSY.Storage` device, `Max[initial_mw,
0]` otherwise, inside `[EnablementMin, EnablementMax]`); and, for a regulation service, `1 ==
agc_status` whenever `agc_status` is known. The daily/profiled-energy pre-condition is not
checked - it reads data this package does not have.

# Returns
`Bool`.
"""
function _fcas_enabled(
        device::PSY.Device, is_regulation::Bool, decremental::Bool, trap::FCASTrapezium,
        curve::PSY.PiecewiseStepData, energy_max_avail::Union{Nothing, Float64},
        initial_mw::Union{Nothing, Float64}, agc_status::Union{Nothing, Int};
        check_stranded::Bool = true,
    )
    get_max_avail(trap) > 0.0 || return false
    any(>(0.0), diff(PSY.get_x_coords(curve))) || return false
    get_enablement_max(trap) >= get_enablement_min(trap) || return false
    _fcas_sign_ok(device, is_regulation, decremental, trap) || return false
    _fcas_energy_max_avail_ok(device, trap, energy_max_avail) || return false
    if check_stranded && !isnothing(initial_mw)
        point = device isa PSY.Storage ? initial_mw : max(initial_mw, 0.0)
        get_enablement_min(trap) <= point <= get_enablement_max(trap) || return false
    end
    is_regulation && !isnothing(agc_status) && agc_status == 0 && return false
    return true
end

"""
    _fcas_both_sides_enabled(device, gen_trap, gen_curve, load_trap, load_curve, agc_status, initial_mw) -> (Bool, Bool)

Whether a `PSY.Storage` device's generation-side and load-side regulation bids are enabled: each
side's own [`_fcas_enabled`](@ref) pre-conditions independently (`check_stranded = false`), and
AEMO *FCAS Model in NEMDE* §5's combined stranded pre-condition for a both-sides regulation bid
(`EnablementMin`<sub>LOAD</sub>` <= initial_mw <= EnablementMax`<sub>GEN</sub>, when `initial_mw`
is known) gating both sides together.

# Returns
`(gen_enabled::Bool, load_enabled::Bool)`.
"""
function _fcas_both_sides_enabled(
        device::PSY.Device, gen_trap::FCASTrapezium, gen_curve::PSY.PiecewiseStepData,
        load_trap::FCASTrapezium, load_curve::PSY.PiecewiseStepData,
        agc_status::Union{Nothing, Int}, initial_mw::Union{Nothing, Float64},
    )
    gen_ok = _fcas_enabled(device, true, false, gen_trap, gen_curve, nothing, nothing, agc_status; check_stranded = false)
    load_ok = _fcas_enabled(device, true, true, load_trap, load_curve, nothing, nothing, agc_status; check_stranded = false)
    stranded_ok = isnothing(initial_mw) || (get_enablement_min(load_trap) <= initial_mw <= get_enablement_max(gen_trap))
    return gen_ok && stranded_ok, load_ok && stranded_ok
end

"""
    _device_regulation_target(container, device, reg_bid_type, t) -> Union{Nothing, JuMP.AbstractJuMPScalar}

`device`'s [`FCASUnitRegulationTarget`](@ref) at `t` for the `reg_bid_type` regulation market it
belongs to, found via `PSY.get_services(device)`. `nothing` when `device` carries no such
service, or that service wasn't built under [`FCASMarket`](@ref) this run.

# Returns
`Union{Nothing, JuMP.AbstractJuMPScalar}`.
"""
function _device_regulation_target(container::PSI.OptimizationContainer, device::PSY.Device, reg_bid_type::BidType, t::Int)
    for svc in PSY.get_services(device)
        svc isa FCASService || continue
        get_bid_type(svc) == reg_bid_type || continue
        name = PSY.get_name(svc)
        PSI.has_container_key(container, FCASUnitRegulationTarget, FCASService, name) || continue
        expr = PSI.get_expression(container, FCASUnitRegulationTarget(), FCASService, name)
        dname = PSY.get_name(device)
        dname in axes(expr, 1) || continue
        return expr[dname, t]
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
    initial_time = PSI.get_initial_time(container)
    horizon = length(time_steps)
    jm = PSI.get_jump_model(container)

    directions = Dict(PSY.get_name(d) => _fcas_direction(d, bid_type) for d in devices)
    both_devices = filter(d -> directions[PSY.get_name(d)] == :both, devices)
    single_devices = filter(d -> directions[PSY.get_name(d)] != :both, devices)
    single_names = PSY.get_name.(single_devices)
    both_names = PSY.get_name.(both_devices)

    if !isempty(single_names)
        var = PSI.add_variable_container!(
            container, FCASCapacityVariable(), FCASService, single_names, time_steps; meta = name,
        )
        upper_lhs = PSI.lazy_container_addition!(
            container, FCASJointCapacityLHS(), FCASService, single_names, time_steps; meta = "$(name)_upper",
        )
        lower_lhs = PSI.lazy_container_addition!(
            container, FCASJointCapacityLHS(), FCASService, single_names, time_steps; meta = "$(name)_lower",
        )
        for device in single_devices
            dname = PSY.get_name(device)
            decremental = directions[dname] == :decremental
            is_storage = device isa PSY.Storage
            initial_mw_at = is_storage ? nothing : _fcas_ts_value_accessor(container, InitialPowerTimeSeriesParameter, typeof(device))
            energy_max_avail_at = is_storage ? nothing : _fcas_ts_value_accessor(container, PSI.ActivePowerTimeSeriesParameter, typeof(device))
            storage_initial_mw = is_storage ? get_storage_initial_mw(device, initial_time, horizon) : nothing
            agc_status = get_fcas_agc_status(device, initial_time, horizon)
            trapeziums, curves = _fcas_series(container, device, bid_type, decremental)
            for t in time_steps
                trap = trapeziums[t]
                initial_mw = if is_storage
                    isnothing(storage_initial_mw) ? nothing : storage_initial_mw[t]
                else
                    isnothing(initial_mw_at) ? nothing : initial_mw_at(dname, t)
                end
                energy_max_avail = isnothing(energy_max_avail_at) ? nothing : energy_max_avail_at(dname, t)
                status = isnothing(agc_status) ? nothing : agc_status[t]
                enabled = _fcas_enabled(device, is_regulation, decremental, trap, curves[t], energy_max_avail, initial_mw, status)
                bound = enabled ? max(get_max_avail(trap), 0.0) : 0.0

                var[dname, t] = JuMP.@variable(
                    jm, base_name = "FCASCapacityVariable_FCASService_$(name)_{$dname, $t}", lower_bound = 0.0,
                )
                JuMP.set_upper_bound(var[dname, t], bound)

                _add_fcas_energy_terms!(container, upper_lhs[dname, t], device, decremental, dname, t)
                JuMP.add_to_expression!(upper_lhs[dname, t], get_upper_slope_coeff(trap), var[dname, t])
                _add_fcas_energy_terms!(container, lower_lhs[dname, t], device, decremental, dname, t)
                JuMP.add_to_expression!(lower_lhs[dname, t], -get_lower_slope_coeff(trap), var[dname, t])
            end
        end
    end

    if !isempty(both_names)
        gen_var = PSI.add_variable_container!(
            container, FCASSideCapacityVariable(), FCASService, both_names, time_steps; meta = "$(name)_gen",
        )
        load_var = PSI.add_variable_container!(
            container, FCASSideCapacityVariable(), FCASService, both_names, time_steps; meta = "$(name)_load",
        )
        gen_upper_lhs = PSI.lazy_container_addition!(
            container, FCASJointCapacityLHS(), FCASService, both_names, time_steps; meta = "$(name)_gen_upper",
        )
        gen_lower_lhs = PSI.lazy_container_addition!(
            container, FCASJointCapacityLHS(), FCASService, both_names, time_steps; meta = "$(name)_gen_lower",
        )
        load_upper_lhs = PSI.lazy_container_addition!(
            container, FCASJointCapacityLHS(), FCASService, both_names, time_steps; meta = "$(name)_load_upper",
        )
        load_lower_lhs = PSI.lazy_container_addition!(
            container, FCASJointCapacityLHS(), FCASService, both_names, time_steps; meta = "$(name)_load_lower",
        )
        for device in both_devices
            dname = PSY.get_name(device)
            gen_traps, gen_curves, load_traps, load_curves = _fcas_regulation_sides(container, device, bid_type)
            storage_initial_mw = get_storage_initial_mw(device, initial_time, horizon)
            agc_status = get_fcas_agc_status(device, initial_time, horizon)
            for t in time_steps
                gen_trap, load_trap = gen_traps[t], load_traps[t]
                initial_mw = isnothing(storage_initial_mw) ? nothing : storage_initial_mw[t]
                status = isnothing(agc_status) ? nothing : agc_status[t]
                gen_enabled, load_enabled = _fcas_both_sides_enabled(
                    device, gen_trap, gen_curves[t], load_trap, load_curves[t], status, initial_mw,
                )
                gen_bound = gen_enabled ? max(get_max_avail(gen_trap), 0.0) : 0.0
                load_bound = load_enabled ? max(get_max_avail(load_trap), 0.0) : 0.0

                gen_var[dname, t] = JuMP.@variable(
                    jm, base_name = "FCASSideCapacityVariable_FCASService_$(name)_gen_{$dname, $t}", lower_bound = 0.0,
                )
                JuMP.set_upper_bound(gen_var[dname, t], gen_bound)
                load_var[dname, t] = JuMP.@variable(
                    jm, base_name = "FCASSideCapacityVariable_FCASService_$(name)_load_{$dname, $t}", lower_bound = 0.0,
                )
                JuMP.set_upper_bound(load_var[dname, t], load_bound)

                _add_fcas_side_energy_terms!(container, gen_upper_lhs[dname, t], device, :gen, dname, t)
                JuMP.add_to_expression!(gen_upper_lhs[dname, t], get_upper_slope_coeff(gen_trap), gen_var[dname, t])
                _add_fcas_side_energy_terms!(container, gen_lower_lhs[dname, t], device, :gen, dname, t)
                JuMP.add_to_expression!(gen_lower_lhs[dname, t], -get_lower_slope_coeff(gen_trap), gen_var[dname, t])

                _add_fcas_side_energy_terms!(container, load_upper_lhs[dname, t], device, :load, dname, t)
                JuMP.add_to_expression!(load_upper_lhs[dname, t], get_upper_slope_coeff(load_trap), load_var[dname, t])
                _add_fcas_side_energy_terms!(container, load_lower_lhs[dname, t], device, :load, dname, t)
                JuMP.add_to_expression!(load_lower_lhs[dname, t], -get_lower_slope_coeff(load_trap), load_var[dname, t])
            end
        end
    end

    if is_regulation
        names = PSY.get_name.(devices)
        target = PSI.add_expression_container!(
            container, FCASUnitRegulationTarget(), FCASService, names, time_steps; meta = name,
        )
        if !isempty(single_names)
            var = PSI.get_variable(container, FCASCapacityVariable(), FCASService, name)
            for dname in single_names, t in time_steps
                target[dname, t] = 1.0 * var[dname, t]
            end
        end
        if !isempty(both_names)
            gen_var = PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(name)_gen")
            load_var = PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(name)_load")
            for dname in both_names, t in time_steps
                target[dname, t] = gen_var[dname, t] + load_var[dname, t]
            end
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

Adds every contributing device's [`_add_fcas_offer_cost!`](@ref) epigraph cost to the objective:
one cost term against a single-sided device's own curve, or two independent cost terms - one per
side - against a `PSY.Storage` device's generation-side and load-side curves.

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
    for device in devices
        dname = PSY.get_name(device)
        direction = _fcas_direction(device, bid_type)
        if direction == :both
            _, gen_curves, _, load_curves = _fcas_regulation_sides(container, device, bid_type)
            gen_var = PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(name)_gen")
            load_var = PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(name)_load")
            for t in time_steps
                _add_fcas_offer_cost!(container, dname, t, gen_var[dname, t], gen_curves[t])
                _add_fcas_offer_cost!(container, dname, t, load_var[dname, t], load_curves[t])
            end
        else
            _, curves = _fcas_series(container, device, bid_type, direction == :decremental)
            fcas_var = PSI.get_variable(container, FCASCapacityVariable(), FCASService, name)
            for t in time_steps
                _add_fcas_offer_cost!(container, dname, t, fcas_var[dname, t], curves[t])
            end
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
    initial_time = PSI.get_initial_time(container)
    horizon = length(time_steps)
    jm = PSI.get_jump_model(container)

    directions = Dict(PSY.get_name(d) => _fcas_direction(d, bid_type) for d in devices)
    both_devices = filter(d -> directions[PSY.get_name(d)] == :both, devices)
    single_devices = filter(d -> directions[PSY.get_name(d)] != :both, devices)
    single_names = PSY.get_name.(single_devices)
    both_names = PSY.get_name.(both_devices)

    # Contingency services carry the regulation targets: `RaiseReg` upper, `LowerReg` lower.
    if !is_regulation && !isempty(single_names)
        upper_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_upper")
        lower_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_lower")
        for device in single_devices
            dname = PSY.get_name(device)
            for t in time_steps
                raise_reg = _device_regulation_target(container, device, BidType.RAISEREG, t)
                isnothing(raise_reg) || JuMP.add_to_expression!(upper_lhs[dname, t], 1.0, raise_reg)
                lower_reg = _device_regulation_target(container, device, BidType.LOWERREG, t)
                isnothing(lower_reg) || JuMP.add_to_expression!(lower_lhs[dname, t], -1.0, lower_reg)
            end
        end
    end

    if !isempty(single_names)
        upper_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_upper")
        lower_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_lower")
        fcas_var = PSI.get_variable(container, FCASCapacityVariable(), FCASService, name)

        con_upper = PSI.add_constraints_container!(
            container, FCASJointCapacityConstraint(), FCASService, single_names, time_steps; meta = "$(name)_upper",
        )
        con_lower = PSI.add_constraints_container!(
            container, FCASJointCapacityConstraint(), FCASService, single_names, time_steps; meta = "$(name)_lower",
        )
        for device in single_devices
            dname = PSY.get_name(device)
            decremental = directions[dname] == :decremental
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
    end

    if !isempty(both_names)
        gen_upper_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_gen_upper")
        gen_lower_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_gen_lower")
        load_upper_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_load_upper")
        load_lower_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_load_lower")
        gen_var = PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(name)_gen")
        load_var = PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(name)_load")

        con_gen_upper = PSI.add_constraints_container!(
            container, FCASJointCapacityConstraint(), FCASService, both_names, time_steps; meta = "$(name)_gen_upper",
        )
        con_gen_lower = PSI.add_constraints_container!(
            container, FCASJointCapacityConstraint(), FCASService, both_names, time_steps; meta = "$(name)_gen_lower",
        )
        con_load_upper = PSI.add_constraints_container!(
            container, FCASJointCapacityConstraint(), FCASService, both_names, time_steps; meta = "$(name)_load_upper",
        )
        con_load_lower = PSI.add_constraints_container!(
            container, FCASJointCapacityConstraint(), FCASService, both_names, time_steps; meta = "$(name)_load_lower",
        )
        for device in both_devices
            dname = PSY.get_name(device)
            gen_traps, _, load_traps, _ = _fcas_regulation_sides(container, device, bid_type)
            for t in time_steps
                if JuMP.upper_bound(gen_var[dname, t]) <= 0.0
                    con_gen_upper[dname, t] = JuMP.@constraint(jm, 0.0 <= 1.0)
                    con_gen_lower[dname, t] = JuMP.@constraint(jm, 0.0 <= 1.0)
                else
                    gen_trap = gen_traps[t]
                    con_gen_upper[dname, t] = JuMP.@constraint(jm, gen_upper_lhs[dname, t] <= get_enablement_max(gen_trap))
                    con_gen_lower[dname, t] = JuMP.@constraint(jm, gen_lower_lhs[dname, t] >= get_enablement_min(gen_trap))
                end
                if JuMP.upper_bound(load_var[dname, t]) <= 0.0
                    con_load_upper[dname, t] = JuMP.@constraint(jm, 0.0 <= 1.0)
                    con_load_lower[dname, t] = JuMP.@constraint(jm, 0.0 <= 1.0)
                else
                    load_trap = load_traps[t]
                    con_load_upper[dname, t] = JuMP.@constraint(jm, load_upper_lhs[dname, t] <= get_enablement_max(load_trap))
                    con_load_lower[dname, t] = JuMP.@constraint(jm, load_lower_lhs[dname, t] >= get_enablement_min(load_trap))
                end
            end
        end

        if is_regulation
            target = PSI.get_expression(container, FCASUnitRegulationTarget(), FCASService, name)
            con_ramp = PSI.add_constraints_container!(
                container, FCASBDURampingConstraint(), FCASService, both_names, time_steps; meta = name,
            )
            for device in both_devices
                dname = PSY.get_name(device)
                ramp_cap = get_fcas_agc_ramp_capability(device, bid_type, initial_time, horizon)
                for t in time_steps
                    cap = isnothing(ramp_cap) ? nothing : ramp_cap[t]
                    con_ramp[dname, t] = isnothing(cap) ?
                        JuMP.@constraint(jm, 0.0 <= 1.0) : JuMP.@constraint(jm, target[dname, t] <= cap)
                end
            end
        end
    end

    if !isempty(PSI.get_duals(model))
        for constraint_type in PSI.get_duals(model)
            if !isempty(single_names)
                PSI.add_dual_container!(
                    container, constraint_type, FCASService, single_names, time_steps; meta = "$(name)_upper",
                )
                PSI.add_dual_container!(
                    container, constraint_type, FCASService, single_names, time_steps; meta = "$(name)_lower",
                )
            end
            if !isempty(both_names)
                PSI.add_dual_container!(
                    container, constraint_type, FCASService, both_names, time_steps; meta = "$(name)_gen_upper",
                )
                PSI.add_dual_container!(
                    container, constraint_type, FCASService, both_names, time_steps; meta = "$(name)_gen_lower",
                )
                PSI.add_dual_container!(
                    container, constraint_type, FCASService, both_names, time_steps; meta = "$(name)_load_upper",
                )
                PSI.add_dual_container!(
                    container, constraint_type, FCASService, both_names, time_steps; meta = "$(name)_load_lower",
                )
            end
        end
    end

    PSI.objective_function!(container, svc, model)
    return
end
