PSI.get_default_time_series_names(::Type{FCASService}, ::Type{FCASMarket}) =
    Dict{Type{<:PSI.TimeSeriesParameter}, String}()


PSI.get_default_attributes(::Type{FCASService}, ::Type{FCASMarket}) = Dict{String, Any}()


_is_regulation_service(bid_type::BidType) = bid_type in FCAS_REGULATION_MARKETS


"""
    _fcas_direction(device, bid_type) -> Symbol

Which of `bid_type`'s `"fcas_trapezium_<bid_type>[_decremental]"` series `device` carries.
Throws `ArgumentError` if neither series is attached, if both are attached on a device other
than a `PSY.Storage` regulation bid (bidirectional FCAS capacity is modeled only for a
`PSY.Storage` device's generation-side and load-side regulation bids), or if a
`PSY.ControllableLoad` carries an incremental series (a load offers FCAS on its decremental
series only).

# Returns
`:incremental`, `:decremental`, or `:both`.
"""
function _fcas_direction(device, bid_type::BidType)
    bid_type_str = string(bid_type)
    has_inc = PSY.has_time_series(device, PSY.SingleTimeSeries, "fcas_trapezium_$bid_type_str")
    has_dec = PSY.has_time_series(device, PSY.SingleTimeSeries, "fcas_trapezium_$(bid_type_str)_decremental")
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
    has_inc && device isa PSY.ControllableLoad && throw(
        ArgumentError(
            "FCASMarket: load \"$(PSY.get_name(device))\" carries an incremental $bid_type_str " *
                "bid; a load offers FCAS on its decremental (`LOAD`-direction) series only.",
        ),
    )
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
    _fcas_net_energy_terms(device) -> Vector{Tuple{DataType, Float64}}

The `PSI.VariableType`s (and their sign) making up `device`'s unit-level "Energy Dispatch
Target": the net `ActivePowerOutVariable - ActivePowerInVariable` for a `PSY.Storage` device,
`ActivePowerVariable` otherwise (a `PSY.ControllableLoad`'s is its consumed MW). Used wherever
AEMO's formulation reads a single, signed unit-level energy term rather than one bid side's own
energy - AEMO *FCAS Model in NEMDE* §6.1's joint ramping constraint and a `PSY.Storage` device's
contingency FCAS.

# Returns
`Vector{Tuple{DataType, Float64}}` of `(VariableType, multiplier)` pairs.
"""
function _fcas_net_energy_terms(device::PSY.Device)
    device isa PSY.Storage && return [(PSI.ActivePowerOutVariable, 1.0), (PSI.ActivePowerInVariable, -1.0)]
    return [(PSI.ActivePowerVariable, 1.0)]
end


"""
    _fcas_upper_regulation_service(device) -> BidType

The regulation service whose target enters `device`'s upper-slope (`<= EnablementMax`) FCAS rows:
`BidType.RAISEREG` for a generating unit, `BidType.LOWERREG` for a `PSY.ControllableLoad`, whose
energy axis is consumption so raising consumption lowers frequency (AEMO *FCAS Model in NEMDE*
§6.1, §6.2). The other regulation service enters the lower-slope rows.

# Returns
`BidType.RAISEREG` or `BidType.LOWERREG`.
"""
_fcas_upper_regulation_service(device::PSY.Device) =
    device isa PSY.ControllableLoad ? BidType.LOWERREG : BidType.RAISEREG


"""
    _fcas_ramp_rate_service(device, bid_type) -> BidType

The regulation service whose AGC ramp-rate series bounds `device`'s joint ramping row for
`bid_type`: `bid_type` itself for a generating unit (`RAISEREG` reads the ramp-up rate, `LOWERREG`
the ramp-down rate), and the other service for a `PSY.ControllableLoad`, whose `LowerReg` row is
bounded by the SCADA ramp-up rate and `RaiseReg` row by the ramp-down rate (§6.1).

# Returns
`BidType.RAISEREG` or `BidType.LOWERREG`.
"""
function _fcas_ramp_rate_service(device::PSY.Device, bid_type::BidType)
    device isa PSY.ControllableLoad || return bid_type
    return bid_type == BidType.RAISEREG ? BidType.LOWERREG : BidType.RAISEREG
end


"""
    _fcas_energy_terms(device, is_regulation, decremental) -> Vector{Tuple{DataType, Float64}}

The `PSI.VariableType`s (and their sign) making up `device`'s FCAS "Energy Dispatch Target": for a
`PSY.Storage` device, the bid side's own energy on regulation (`ActivePowerOutVariable` for a
generation-side bid, `-ActivePowerInVariable` for a load-side one) and the net
([`_fcas_net_energy_terms`](@ref)) on contingency; `ActivePowerVariable` otherwise, which for a
`PSY.ControllableLoad` is its consumed MW. Throws `ArgumentError` for a decremental
(`LOAD`-direction) bid on a device that is neither `PSY.Storage` nor a `PSY.ControllableLoad`.

# Returns
`Vector{Tuple{DataType, Float64}}` of `(VariableType, multiplier)` pairs.
"""
function _fcas_energy_terms(device::PSY.Device, is_regulation::Bool, decremental::Bool)
    if device isa PSY.Storage
        is_regulation || return _fcas_net_energy_terms(device)
        return decremental ? [(PSI.ActivePowerInVariable, -1.0)] : [(PSI.ActivePowerOutVariable, 1.0)]
    end
    decremental && !(device isa PSY.ControllableLoad) && throw(
        ArgumentError(
            "FCASMarket: \"$(PSY.get_name(device))\" ($(typeof(device))) has a decremental FCAS " *
                "bid but is neither a `PSY.Storage` device nor a `PSY.ControllableLoad`.",
        ),
    )
    return _fcas_net_energy_terms(device)
end


"""
    _add_fcas_net_energy_terms!(container, expr, device, dname, t)

Adds `device`'s net FCAS energy term ([`_fcas_net_energy_terms`](@ref)) into `expr` at
`(dname, t)`. Throws `ArgumentError` if `device`'s formulation defines no such energy variable.
"""
function _add_fcas_net_energy_terms!(container, expr, device::PSY.Device, dname::AbstractString, t::Int)
    _add_fcas_variable_terms!(container, expr, device, _fcas_net_energy_terms(device), dname, t)
    return
end


"""
    _add_fcas_energy_terms!(container, expr, device, is_regulation, decremental, dname, t)

Adds `device`'s FCAS energy terms ([`_fcas_energy_terms`](@ref)) into `expr` at `(dname, t)`.
Throws `ArgumentError` if `device`'s formulation defines no such energy variable.
"""
function _add_fcas_energy_terms!(
        container, expr, device::PSY.Device, is_regulation::Bool, decremental::Bool, dname::AbstractString, t::Int,
    )
    _add_fcas_variable_terms!(container, expr, device, _fcas_energy_terms(device, is_regulation, decremental), dname, t)
    return
end


"""
    _add_fcas_variable_terms!(container, expr, device, terms, dname, t)

Adds each `(VariableType, multiplier)` of `terms` for `device` into `expr` at `(dname, t)`.
Throws `ArgumentError` if `device`'s formulation defines no such variable.
"""
function _add_fcas_variable_terms!(container, expr, device::PSY.Device, terms, dname::AbstractString, t::Int)
    for (var_type, multiplier) in terms
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
    _add_fcas_variable_terms!(container, expr, device, _fcas_side_energy_terms(side), dname, t)
    return
end


"""
    _fcas_process(container, devices_template, device) -> Symbol

The AEMO central dispatch process `device`'s FCAS telemetry timing follows: `:dispatch` unless
its dispatch model is [`NEMLookaheadDispatch`](@ref), then `:p5min` (5-minute pre-dispatch) at a
5-minute resolution and `:predispatch` (30-minute pre-dispatch) at a longer one. Telemetered
inputs (`INITIALMW`, AGC limits and status) apply to every interval of `:dispatch` and to the
first interval otherwise.

# Returns
`:dispatch`, `:p5min` or `:predispatch`.
"""
function _fcas_process(container::PSI.OptimizationContainer, devices_template, device::PSY.Device)
    for model in values(devices_template)
        PSI.get_component_type(model) == typeof(device) || continue
        PSI.get_formulation(model) <: NEMLookaheadDispatch || return :dispatch
        return PSI.get_resolution(container) > Minute(5) ? :predispatch : :p5min
    end
    return :dispatch
end


"""
    _fcas_agc_ramp_applies(process, t) -> Bool

Whether AEMO *FCAS Model in NEMDE* §4.2 AGC ramp scaling, §6.1 joint ramping and §6.4 BDU SCADA
ramping apply at interval `t` of `process` ([`_fcas_process`](@ref)): every interval in dispatch,
the first in 5-minute pre-dispatch, none in 30-minute pre-dispatch.

# Returns
`Bool`.
"""
_fcas_agc_ramp_applies(process::Symbol, t::Int) = process === :dispatch || (process === :p5min && t == 1)


"""
    _fcas_window(container, devices_template, device) -> NamedTuple

The intervals `device`'s FCAS inputs are read over in `container`: `(initial_time, horizon,
resolution, process)`, `horizon` being the number of time steps and `process` the
[`_fcas_process`](@ref) of `device`'s formulation.

# Returns
`NamedTuple{(:initial_time, :horizon, :resolution, :process)}`.
"""
function _fcas_window(container::PSI.OptimizationContainer, devices_template, device::PSY.Device)
    return (
        initial_time = PSI.get_initial_time(container), horizon = length(PSI.get_time_steps(container)),
        resolution = PSI.get_resolution(container), process = _fcas_process(container, devices_template, device),
    )
end


"""
    _fcas_series(window, device, bid_type, decremental) -> (trapeziums, curves)
    _fcas_series(container, devices_template, device, bid_type, decremental) -> (trapeziums, curves)

`device`'s FCAS trapezium and offer-curve series for `bid_type`, one entry per interval of
`window` ([`_fcas_window`](@ref)), read via
[`get_scaled_fcas_trapezium`](@ref)/[`get_fcas_offer_curve`](@ref). The trapezium is AEMO
*FCAS Model in NEMDE* §4's scaled/effective trapezium wherever `device` carries the scaling
input series ([`set_fcas_scaling_inputs!`](@ref)), with the AGC ramping capability taken over the
window's resolution, following the window's process: every interval in dispatch; AGC enablement
and ramp scaling on the first interval only in 5-minute pre-dispatch; AGC enablement scaling on
the first interval only and no ramp scaling in 30-minute pre-dispatch. Otherwise it is the bid
trapezium unscaled.

# Returns
`(trapeziums::Vector{FCASTrapezium}, curves::Vector{PSY.PiecewiseStepData})`.
"""
function _fcas_series(window::NamedTuple, device, bid_type::BidType, decremental::Bool)
    trapeziums = get_scaled_fcas_trapezium(
        device, bid_type, window.initial_time, window.horizon; decremental = decremental,
        resolution = window.resolution, agc_first_interval_only = window.process !== :dispatch,
        agc_ramp_scaling = window.process !== :predispatch,
    )
    return trapeziums, _fcas_offer_curves(window, device, bid_type, decremental)
end
function _fcas_series(
        container::PSI.OptimizationContainer, devices_template, device, bid_type::BidType, decremental::Bool,
    )
    return _fcas_series(_fcas_window(container, devices_template, device), device, bid_type, decremental)
end


"`device`'s FCAS offer curves for `bid_type`, one per interval of `window` ([`get_fcas_offer_curve`](@ref))."
function _fcas_offer_curves(window::NamedTuple, device, bid_type::BidType, decremental::Bool)
    return get_fcas_offer_curve(device, bid_type, window.initial_time, window.horizon; decremental = decremental)
end


"""
    _fcas_regulation_sides(window, device, bid_type) -> (gen_trapeziums, gen_curves, load_trapeziums, load_curves)

A `PSY.Storage` device's generation-side and load-side trapezium and offer-curve series
([`_fcas_series`](@ref)) for a regulation `bid_type` it bids on both sides.

# Returns
`(gen_trapeziums::Vector{FCASTrapezium}, gen_curves::Vector{PSY.PiecewiseStepData}, load_trapeziums::Vector{FCASTrapezium}, load_curves::Vector{PSY.PiecewiseStepData})`.
"""
function _fcas_regulation_sides(window::NamedTuple, device, bid_type::BidType)
    gen_trapeziums, gen_curves = _fcas_series(window, device, bid_type, false)
    load_trapeziums, load_curves = _fcas_series(window, device, bid_type, true)
    return gen_trapeziums, gen_curves, load_trapeziums, load_curves
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
        curve::PSY.PiecewiseStepData,
        energy_max_avail::Union{Nothing, Float64, NamedTuple{(:gen, :load), Tuple{Float64, Float64}}},
        initial_mw::Union{Nothing, Float64}, agc_status::Union{Nothing, Int};
        check_stranded::Bool = true,
    )
    get_max_avail(trap) > 0.0 || return false
    any(>(0.0), diff(PSY.get_x_coords(curve))) || return false
    get_enablement_max(trap) >= get_enablement_min(trap) || return false
    _fcas_sign_ok(device, is_regulation, decremental, trap) || return false
    _fcas_energy_max_avail_ok(device, is_regulation, decremental, trap, energy_max_avail) || return false
    if check_stranded && !isnothing(initial_mw)
        point = device isa PSY.Storage ? initial_mw : max(initial_mw, 0.0)
        get_enablement_min(trap) <= point <= get_enablement_max(trap) || return false
    end
    is_regulation && !isnothing(agc_status) && agc_status == 0 && return false
    return true
end


"""
    _storage_energy_max_avail_at(avail, t) -> Union{Nothing, NamedTuple}

Interval `t` of a [`get_storage_energy_max_avail`](@ref) result, as `(gen = ..., load = ...)`,
or `nothing` when `avail` is `nothing`.

# Returns
`Union{Nothing, NamedTuple{(:gen, :load), Tuple{Float64, Float64}}}`.
"""
_storage_energy_max_avail_at(avail, t::Int) = isnothing(avail) ? nothing : (gen = avail.gen[t], load = avail.load[t])


"""
    _fcas_both_sides_enabled(device, gen_trap, gen_curve, load_trap, load_curve, agc_status, initial_mw, energy_max_avail) -> (Bool, Bool)

Whether a `PSY.Storage` device's generation-side and load-side regulation bids are enabled: each
side's own [`_fcas_enabled`](@ref) pre-conditions independently (`check_stranded = false`,
`energy_max_avail` as for a single-sided `PSY.Storage` bid), then, when `initial_mw` is known, the
"stranded" pre-condition. When both sides pass their own pre-conditions, AEMO *FCAS Model in
NEMDE* §5's combined form (`EnablementMin`<sub>LOAD</sub>` <= initial_mw <= EnablementMax`<sub>GEN</sub>)
gates both together; otherwise the one side still enabled is checked against its own trapezium.

# Returns
`(gen_enabled::Bool, load_enabled::Bool)`.
"""
function _fcas_both_sides_enabled(
        device::PSY.Device, gen_trap::FCASTrapezium, gen_curve::PSY.PiecewiseStepData,
        load_trap::FCASTrapezium, load_curve::PSY.PiecewiseStepData,
        agc_status::Union{Nothing, Int}, initial_mw::Union{Nothing, Float64},
        energy_max_avail::Union{Nothing, NamedTuple{(:gen, :load), Tuple{Float64, Float64}}},
    )
    gen_ok = _fcas_enabled(device, true, false, gen_trap, gen_curve, energy_max_avail, nothing, agc_status; check_stranded = false)
    load_ok = _fcas_enabled(device, true, true, load_trap, load_curve, energy_max_avail, nothing, agc_status; check_stranded = false)
    isnothing(initial_mw) && return gen_ok, load_ok
    if gen_ok && load_ok
        combined = get_enablement_min(load_trap) <= initial_mw <= get_enablement_max(gen_trap)
        return combined, combined
    end
    within(trap) = get_enablement_min(trap) <= initial_mw <= get_enablement_max(trap)
    return gen_ok && within(gen_trap), load_ok && within(load_trap)
end


"""
    _fcas_enablement_inputs(window, device) -> (initial_mw, availability, agc_status)
    _fcas_enablement_inputs(container, devices_template, device) -> (initial_mw, availability, agc_status)

`device`'s per-interval §5 inputs over `window` ([`_fcas_window`](@ref)): `InitialMW`
([`get_initial_mw`](@ref)), energy availability ([`get_storage_energy_max_avail`](@ref) as
`(gen = ..., load = ...)` for a `PSY.Storage` device, [`get_energy_availability`](@ref) otherwise)
and AGC status ([`get_fcas_agc_status`](@ref)), each a function of `t` returning `nothing` where
unknown. Outside dispatch `InitialMW` and AGC status are known in the first interval only.

# Returns
`(initial_mw::Function, availability::Function, agc_status::Function)`.
"""
function _fcas_enablement_inputs(window::NamedTuple, device::PSY.Device)
    first_only = window.process !== :dispatch
    initial_mw = get_initial_mw(device, window.initial_time, window.horizon)
    agc_status = get_fcas_agc_status(device, window.initial_time, window.horizon)
    telemetry(series, t) = (isnothing(series) || (first_only && t > 1)) ? nothing : series[t]
    availability_at = if device isa PSY.Storage
        storage = get_storage_energy_max_avail(device, window.initial_time, window.horizon)
        t -> _storage_energy_max_avail_at(storage, t)
    else
        avail = get_energy_availability(device, window.initial_time, window.horizon)
        t -> isnothing(avail) ? nothing : avail[t]
    end
    return (t -> telemetry(initial_mw, t), availability_at, t -> telemetry(agc_status, t))
end
function _fcas_enablement_inputs(container::PSI.OptimizationContainer, devices_template, device::PSY.Device)
    return _fcas_enablement_inputs(_fcas_window(container, devices_template, device), device)
end


"""
    _fcas_enabled_mask(window, device, bid_type, decremental) -> Vector{Bool}
    _fcas_enabled_mask(container, devices_template, device, bid_type, decremental) -> Vector{Bool}

Per-interval [`_fcas_enabled`](@ref) for `device`'s one-directional `bid_type` bid, on the
[`_fcas_enablement_inputs`](@ref) over `window`.

# Returns
`Vector{Bool}`, one entry per interval of `window`.
"""
function _fcas_enabled_mask(window::NamedTuple, device::PSY.Device, bid_type::BidType, decremental::Bool)
    is_regulation = _is_regulation_service(bid_type)
    trapeziums, curves = _fcas_series(window, device, bid_type, decremental)
    initial_mw, availability, agc_status = _fcas_enablement_inputs(window, device)
    return map(1:window.horizon) do t
        _fcas_enabled(
            device, is_regulation, decremental, trapeziums[t], curves[t], availability(t), initial_mw(t), agc_status(t),
        )
    end
end
function _fcas_enabled_mask(
        container::PSI.OptimizationContainer, devices_template, device::PSY.Device, bid_type::BidType, decremental::Bool,
    )
    return _fcas_enabled_mask(_fcas_window(container, devices_template, device), device, bid_type, decremental)
end


"""
    _fcas_both_sides_enabled_mask(window, device, bid_type) -> (Vector{Bool}, Vector{Bool})

Per-interval [`_fcas_both_sides_enabled`](@ref) for a `PSY.Storage` device bidding regulation
`bid_type` on both sides, on the [`_fcas_enablement_inputs`](@ref) over `window`.

# Returns
`(gen_enabled::Vector{Bool}, load_enabled::Vector{Bool})`.
"""
function _fcas_both_sides_enabled_mask(window::NamedTuple, device::PSY.Device, bid_type::BidType)
    gen_traps, gen_curves, load_traps, load_curves = _fcas_regulation_sides(window, device, bid_type)
    initial_mw, availability, agc_status = _fcas_enablement_inputs(window, device)
    flags = map(1:window.horizon) do t
        _fcas_both_sides_enabled(
            device, gen_traps[t], gen_curves[t], load_traps[t], load_curves[t], agc_status(t), initial_mw(t), availability(t),
        )
    end
    return first.(flags), last.(flags)
end


"""
    _fcas_agc_ramp_caps(window, device, bid_type) -> Vector{Float64}
    _fcas_agc_ramp_caps(container, devices_template, device, bid_type) -> Vector{Float64}

`device`'s AGC ramping capability on its regulation `bid_type` target, one entry per interval of
`window`: the AGC ramping capability ([`get_fcas_agc_ramp_capability`](@ref)) over the window's
resolution wherever [`_fcas_agc_ramp_applies`](@ref), `0.0` (no cap) elsewhere or where the ramp
rate is zero or absent. Used by AEMO *FCAS Model in NEMDE* §6.1's joint ramping constraint (any
device) and §6.4's BDU SCADA ramping constraint (a `PSY.Storage` device bidding both sides).

# Returns
`Vector{Float64}`.
"""
function _fcas_agc_ramp_caps(window::NamedTuple, device::PSY.Device, bid_type::BidType)
    ramp_cap = get_fcas_agc_ramp_capability(
        device, bid_type, window.initial_time, window.horizon; resolution = window.resolution,
    )
    return [
        (isnothing(ramp_cap) || isnan(ramp_cap[t]) || !_fcas_agc_ramp_applies(window.process, t)) ? 0.0 : ramp_cap[t]
            for t in 1:window.horizon
    ]
end
function _fcas_agc_ramp_caps(container::PSI.OptimizationContainer, devices_template, device::PSY.Device, bid_type::BidType)
    return _fcas_agc_ramp_caps(_fcas_window(container, devices_template, device), device, bid_type)
end


"""
    _fcas_regulation_enabled_mask(window, device, bid_type, direction) -> Vector{Bool}

`device`'s per-interval enablement for regulation `bid_type`, for the unit as a whole:
[`_fcas_enabled_mask`](@ref) for a single-sided `direction` (`:incremental`/`:decremental`), or,
for `direction == :both` (a `PSY.Storage` device bidding both sides), either side enabled
([`_fcas_both_sides_enabled_mask`](@ref)).

# Returns
`Vector{Bool}`, one entry per interval of `window`.
"""
function _fcas_regulation_enabled_mask(window::NamedTuple, device::PSY.Device, bid_type::BidType, direction::Symbol)
    if direction == :both
        gen_enabled, load_enabled = _fcas_both_sides_enabled_mask(window, device, bid_type)
        return gen_enabled .| load_enabled
    end
    return _fcas_enabled_mask(window, device, bid_type, direction == :decremental)
end


"""
    FCAS_BAND_COUNT

The number of price bands of an FCAS offer, `BANDAVAIL1` to `BANDAVAIL10` of `BIDPEROFFER_D`.
"""
const FCAS_BAND_COUNT = 10


"""
    FCAS_INACTIVE_LIMIT_MW

Right-hand side, in MW, of an FCAS row at an interval where it does not apply (an offer not enabled
under AEMO *FCAS Model in NEMDE* §5, or a ramping row without a ramp rate or `InitialMW`):
`+FCAS_INACTIVE_LIMIT_MW` for a `<=` row and `-FCAS_INACTIVE_LIMIT_MW` for a `>=` row. It is two
orders of magnitude above any one unit's energy plus FCAS, so the row never binds.
"""
const FCAS_INACTIVE_LIMIT_MW = 1.0e5


"`\"fcas_effective_<BIDTYPE>[_decremental]\"`, the [`set_fcas_effective_offers!`](@ref) series of one FCAS offer."
_fcas_effective_series_name(bid_type::BidType, decremental::Bool) =
    AustralianElectricityMarkets._fcas_series_name("fcas_effective", bid_type, decremental)


"`\"fcas_ramping_limits_<BIDTYPE>\"`, the [`set_fcas_effective_offers!`](@ref) series of one regulation market."
_fcas_ramping_series_name(bid_type::BidType) = "fcas_ramping_limits_$(string(bid_type))"


"The meta of an FCAS offer's parameters: `\"<BIDTYPE>\"`, or `\"<BIDTYPE>_decremental\"` for a decremental offer."
_fcas_offer_meta(bid_type::BidType, decremental::Bool) = decremental ? "$(string(bid_type))_decremental" : string(bid_type)


"The `decremental` flag of each offer a device bidding in `direction` makes: one, or two for `:both`."
function _fcas_offer_sides(direction::Symbol)
    direction == :both && return (false, true)
    return (direction == :decremental,)
end


"""
    _fcas_effective_offer(trap, curve, enabled, inactive) -> NTuple{15, Float64}

One interval of an FCAS offer's `"fcas_effective_..."` series, per-unit of the system base:
`(MaxAvail, EnablementMin, EnablementMax, UpperSlopeCoeff, LowerSlopeCoeff, w1, ..., w10)` of the
effective trapezium `trap` and the band widths of `curve`, padded with zero widths to
[`FCAS_BAND_COUNT`](@ref). An offer that is not `enabled` has zero `MaxAvail`, slopes and widths,
and enablement limits `-inactive` and `inactive`. Throws `ArgumentError` for a curve with more than
`FCAS_BAND_COUNT` bands.

# Returns
`NTuple{15, Float64}`.
"""
function _fcas_effective_offer(trap::FCASTrapezium, curve::PSY.PiecewiseStepData, enabled::Bool, inactive::Float64)
    widths = diff(PSY.get_x_coords(curve))
    length(widths) <= FCAS_BAND_COUNT || throw(
        ArgumentError("FCAS offer curve has $(length(widths)) bands, more than $FCAS_BAND_COUNT."),
    )
    padded = ntuple(i -> (enabled && i <= length(widths)) ? widths[i] : 0.0, FCAS_BAND_COUNT)
    enabled || return (0.0, -inactive, inactive, 0.0, 0.0, padded...)
    return (
        get_max_avail(trap), get_enablement_min(trap), get_enablement_max(trap),
        get_upper_slope_coeff(trap), get_lower_slope_coeff(trap), padded...,
    )
end


"""
    _fcas_effective_ramping(window, device, bid_type, direction, inactive) -> Vector{NTuple{2, Float64}}

`device`'s regulation ramping limits for `bid_type` over `window`, per-unit of the system base:
`(joint, bdu)` per interval. `joint` is the AEMO *FCAS Model in NEMDE* §6.1 right-hand side,
`InitialMW` plus the AGC ramping capability of [`_fcas_ramp_rate_service`](@ref) on the upper form
([`_fcas_upper_regulation_service`](@ref)) or minus it on the lower form, and `±inactive` wherever the
capability is zero, `InitialMW` is unknown or the unit is not enabled for `bid_type`
([`_fcas_regulation_enabled_mask`](@ref)). `bdu` is the §6.4 right-hand side of a `PSY.Storage` device
bidding both sides, its AGC ramping capability on `bid_type`, and `inactive` where that is zero or
for any other device.

# Returns
`Vector{NTuple{2, Float64}}`, one entry per interval of `window`.
"""
function _fcas_effective_ramping(window::NamedTuple, device::PSY.Device, bid_type::BidType, direction::Symbol, inactive::Float64)
    caps = _fcas_agc_ramp_caps(window, device, _fcas_ramp_rate_service(device, bid_type))
    initial_mw = get_initial_mw(device, window.initial_time, window.horizon)
    enabled = _fcas_regulation_enabled_mask(window, device, bid_type, direction)
    upper = bid_type == _fcas_upper_regulation_service(device)
    bdu_caps = direction == :both ? _fcas_agc_ramp_caps(window, device, bid_type) : nothing
    return map(1:window.horizon) do t
        mw = isnothing(initial_mw) ? NaN : initial_mw[t]
        joint = if iszero(caps[t]) || isnan(mw) || !enabled[t]
            upper ? inactive : -inactive
        else
            upper ? mw + caps[t] : mw - caps[t]
        end
        bdu = (isnothing(bdu_caps) || iszero(bdu_caps[t])) ? inactive : bdu_caps[t]
        (joint, bdu)
    end
end


"""
    _fcas_effective_values(window, device, bid_type, direction, inactive) -> (offers, ramping)

`device`'s effective FCAS offers for `bid_type` over `window`: `offers` maps each offer's
`decremental` flag to its [`_fcas_effective_offer`](@ref) per interval, enabled by
[`_fcas_both_sides_enabled_mask`](@ref) for a `PSY.Storage` device's regulation bid on both sides and
by [`_fcas_enabled_mask`](@ref) otherwise; `ramping` is [`_fcas_effective_ramping`](@ref) for a
regulation market, `nothing` otherwise.

# Returns
`(offers::Dict{Bool, Vector{NTuple{15, Float64}}}, ramping::Union{Nothing, Vector{NTuple{2, Float64}}})`.
"""
function _fcas_effective_values(window::NamedTuple, device::PSY.Device, bid_type::BidType, direction::Symbol, inactive::Float64)
    enabled = if direction == :both && device isa PSY.Storage && _is_regulation_service(bid_type)
        gen, load = _fcas_both_sides_enabled_mask(window, device, bid_type)
        Dict(false => gen, true => load)
    else
        Dict(dec => _fcas_enabled_mask(window, device, bid_type, dec) for dec in _fcas_offer_sides(direction))
    end
    offers = Dict{Bool, Vector{NTuple{15, Float64}}}()
    for (decremental, mask) in enabled
        trapeziums, curves = _fcas_series(window, device, bid_type, decremental)
        offers[decremental] = [_fcas_effective_offer(trapeziums[t], curves[t], mask[t], inactive) for t in 1:window.horizon]
    end
    _is_regulation_service(bid_type) || return offers, nothing
    return offers, _fcas_effective_ramping(window, device, bid_type, direction, inactive)
end


# Field axes of the FCAS time-series parameters and the slices of a series element each reads.
const _FCAS_LIMIT_FIELDS = ["max_avail", "enablement_min", "enablement_max"]
const _FCAS_RAMPING_FIELDS = ["joint_ramping", "bdu_ramping"]
const _FCAS_BAND_LABELS = string.(1:FCAS_BAND_COUNT)
const _FCAS_OFFER_PARAMETERS = (FCASOfferLimitParameter, FCASBandWidthParameter, FCASUpperSlopeParameter, FCASLowerSlopeParameter)

_fcas_parameter_axes(::FCASOfferLimitParameter) = (_FCAS_LIMIT_FIELDS,)
_fcas_parameter_axes(::FCASBandWidthParameter) = (_FCAS_BAND_LABELS,)
_fcas_parameter_axes(::FCASRampingLimitParameter) = (_FCAS_RAMPING_FIELDS,)
_fcas_parameter_axes(::Union{FCASUpperSlopeParameter, FCASLowerSlopeParameter}) = ()

PSI._unwrap_for_param(::FCASOfferLimitParameter, v::NTuple{15, Float64}, _) = [v[1], v[2], v[3]]
PSI._unwrap_for_param(::FCASUpperSlopeParameter, v::NTuple{15, Float64}, _) = v[4]
PSI._unwrap_for_param(::FCASLowerSlopeParameter, v::NTuple{15, Float64}, _) = v[5]
PSI._unwrap_for_param(::FCASBandWidthParameter, v::NTuple{15, Float64}, _) = collect(v[6:15])
PSI._unwrap_for_param(::FCASRampingLimitParameter, v::NTuple{2, Float64}, _) = [v[1], v[2]]


"`devices_template`'s `PSI.DeviceModel` for component type `D`."
function _fcas_device_model(devices_template, ::Type{D}) where {D <: PSY.Device}
    for model in values(devices_template)
        PSI.get_component_type(model) == D && return model
    end
    throw(ArgumentError("FCASMarket: the template has no device model for $D."))
end


"""
    _add_fcas_parameter!(container, param, model, sys, ts_name, meta)

Adds `param`, keyed by `model`'s component type and `meta`, unless it exists: one row per available
component of `model` carrying a `ts_name` forecast, which is exactly the set PowerSimulations'
time-series parameter update visits. Values are `PowerSimulations._unwrap_for_param` of each
interval's series element; multipliers are `1.0`.

# Returns
`nothing`.
"""
function _add_fcas_parameter!(
        container::PSI.OptimizationContainer, param::T, model::PSI.DeviceModel{D}, sys::PSY.System,
        ts_name::String, meta::String,
    ) where {T <: PSI.TimeSeriesParameter, D <: PSY.Device}
    PSI.has_container_key(container, T, D, meta) && return
    ts_type = PSI.get_default_time_series_type(container)
    devices = [d for d in PSI.get_available_components(model, sys) if PSY.has_time_series(d, ts_type, ts_name)]
    isempty(devices) && return
    settings = PSI.get_settings(container)
    interval, resolution = PSI.get_interval(settings), PSI.get_resolution(settings)
    names = PSY.get_name.(devices)
    uuids = [
        string(
            IS.get_time_series_uuid(
                ts_type, d, ts_name; resolution = PSI._to_is_resolution(resolution), interval = PSI._to_is_interval(interval),
            ),
        ) for d in devices
    ]
    axes = _fcas_parameter_axes(param)
    time_steps = PSI.get_time_steps(container)
    param_container = PSI.add_param_container!(
        container, param, D, ts_type, ts_name, uuids, names, axes, time_steps; meta = meta,
    )
    attributes = PSI.get_attributes(param_container)
    PSI.set_subsystem!(attributes, PSI.get_subsystem(model))
    jm = PSI.get_jump_model(container)
    values = PSI.get_parameter_array_data(param_container)
    multipliers = PSI.get_multiplier_array_data(param_container)
    for (i, d) in enumerate(devices)
        raw = PSI.get_time_series_initial_values!(container, ts_type, d, ts_name; interval = interval, resolution = resolution)
        for t in time_steps
            PSI._set_parameter_at!(values, jm, PSI._unwrap_for_param(param, raw[t], axes), i, t)
        end
        PSI._set_multiplier_at!(multipliers, 1.0, i)
        PSI.add_component_name!(attributes, names[i], uuids[i])
    end
    return
end


# Overwrites `name`'s row of the `param` container keyed `(D, meta)` with `values`, one series element per time step.
function _overwrite_fcas_parameter!(container::PSI.OptimizationContainer, param, ::Type{D}, meta::String, name::String, values) where {D}
    param_container = PSI.get_parameter(container, param, D, meta)
    array = PSI.get_parameter_array(param_container)
    row = array.lookup[1][PSI._get_ts_uuid(PSI.get_attributes(param_container), name)]
    data = PSI.get_parameter_array_data(param_container)
    axes = _fcas_parameter_axes(param)
    for (t, value) in enumerate(values)
        if isempty(axes)
            data[row, t] = PSI._unwrap_for_param(param, value, axes)
        else
            data[row, :, t] .= PSI._unwrap_for_param(param, value, axes)
        end
    end
    return
end


"""
    _check_fcas_effective_series(container, devices, bid_type, directions)

Throws `ArgumentError` naming every device in `devices` without a forecast of its
[`set_fcas_effective_offers!`](@ref) series for `bid_type`.

# Returns
`nothing`.
"""
function _check_fcas_effective_series(container::PSI.OptimizationContainer, devices, bid_type::BidType, directions)
    ts_type = PSI.get_default_time_series_type(container)
    uncovered = String[]
    for d in devices
        dname = PSY.get_name(d)
        names = [_fcas_effective_series_name(bid_type, dec) for dec in _fcas_offer_sides(directions[dname])]
        _is_regulation_service(bid_type) && push!(names, _fcas_ramping_series_name(bid_type))
        all(n -> PSY.has_time_series(d, ts_type, n), names) || push!(uncovered, dname)
    end
    isempty(uncovered) || throw(
        ArgumentError(
            "FCASMarket: $(length(uncovered)) device(s) carry no effective $(string(bid_type)) offer forecast: " *
                "$(join(uncovered, ", ")). Call set_fcas_effective_offers!(sys) before transform_single_time_series!.",
        ),
    )
    return
end


"""
    _add_fcas_offer_parameters!(container, sys, devices_template, devices, bid_type, directions)

Adds the [`FCASOfferLimitParameter`](@ref), [`FCASBandWidthParameter`](@ref),
[`FCASUpperSlopeParameter`](@ref) and [`FCASLowerSlopeParameter`](@ref) of every offer of `devices`
in `bid_type`, and the [`FCASRampingLimitParameter`](@ref) of a regulation market, each keyed by
device type and shared by every service of that market. A device under [`NEMLookaheadDispatch`](@ref)
has its rows overwritten with the effective values of its own process over the model's window
([`_fcas_effective_values`](@ref)); that is rejected in a recurrent build.

# Returns
`nothing`.
"""
function _add_fcas_offer_parameters!(
        container::PSI.OptimizationContainer, sys::PSY.System, devices_template, devices, bid_type::BidType, directions,
    )
    regulation = _is_regulation_service(bid_type)
    for device in devices
        model = _fcas_device_model(devices_template, typeof(device))
        for decremental in _fcas_offer_sides(directions[PSY.get_name(device)])
            name, meta = _fcas_effective_series_name(bid_type, decremental), _fcas_offer_meta(bid_type, decremental)
            for P in _FCAS_OFFER_PARAMETERS
                _add_fcas_parameter!(container, P(), model, sys, name, meta)
            end
        end
        regulation && _add_fcas_parameter!(
            container, FCASRampingLimitParameter(), model, sys, _fcas_ramping_series_name(bid_type), string(bid_type),
        )
    end
    inactive = FCAS_INACTIVE_LIMIT_MW / PSI.get_base_power(container)
    for device in devices
        dname = PSY.get_name(device)
        window = _fcas_window(container, devices_template, device)
        window.process === :dispatch && continue
        PSI.built_for_recurrent_solves(container) && throw(
            ArgumentError(
                "FCASMarket: \"$dname\" is modeled under NEMLookaheadDispatch, whose FCAS inputs depend on the " *
                    "interval's position in the horizon; a recurrent simulation supports NEMReplayDispatch only.",
            ),
        )
        offers, ramping = _fcas_effective_values(window, device, bid_type, directions[dname], inactive)
        for (decremental, values) in offers, P in _FCAS_OFFER_PARAMETERS
            _overwrite_fcas_parameter!(container, P(), typeof(device), _fcas_offer_meta(bid_type, decremental), dname, values)
        end
        isnothing(ramping) || _overwrite_fcas_parameter!(
            container, FCASRampingLimitParameter(), typeof(device), string(bid_type), dname, ramping,
        )
    end
    return
end


"`device`'s column of the `P` parameter keyed `(typeof(device), meta)`, and that parameter's multiplier array."
function _fcas_parameter_refs(container::PSI.OptimizationContainer, ::Type{P}, device::PSY.Device, meta::String) where {P}
    param_container = PSI.get_parameter(container, P(), typeof(device), meta)
    return PSI.get_parameter_column_refs(param_container, PSY.get_name(device)), PSI.get_multiplier_array(param_container)
end


# A parameter cell's value: the number itself, or the fixed value of a recurrent build's JuMP parameter.
_fixed_value(x::Float64) = x
_fixed_value(x::JuMP.VariableRef) = JuMP.fix_value(x)


"""
    _fcas_capacity_bound(container, device, bid_type, decremental) -> Float64

The largest effective `MaxAvail` of `device`'s `bid_type` offer on one side, per-unit: over its whole
`"fcas_effective_..."` series and the model's current [`FCASOfferLimitParameter`](@ref) values,
which differ from the series only under [`NEMLookaheadDispatch`](@ref).

# Returns
`Float64`.
"""
function _fcas_capacity_bound(container::PSI.OptimizationContainer, device::PSY.Device, bid_type::BidType, decremental::Bool)
    meta = _fcas_offer_meta(bid_type, decremental)
    series = PSY.get_time_series_values(PSY.SingleTimeSeries, device, _fcas_effective_series_name(bid_type, decremental))
    limits, _ = _fcas_parameter_refs(container, FCASOfferLimitParameter, device, meta)
    window = maximum(_fixed_value(limits["max_avail", t]) for t in PSI.get_time_steps(container))
    return max(maximum(first, series), window)
end


# A capacity variable's static upper bound: the largest effective MaxAvail without slacks, where the
# MaxAvail row is hard; with slacks only a zero bound, for an offer never enabled.
function _set_fcas_capacity_bound!(model::PSI.ServiceModel, variable, bound::Float64)
    PSI.get_use_slacks(model) && !iszero(bound) && return
    JuMP.set_upper_bound(variable, bound)
    return
end


"""
    FCAS_CAPACITY_CVP_FACTOR

CVP factor (70) of AEMO's FCAS EnablementMin/EnablementMax constraint, item 24 of the *Schedule of
Constraint Violation Penalty Factors* v8.0. Prices [`FCASJointCapacitySlack`](@ref).
"""
const FCAS_CAPACITY_CVP_FACTOR = 70.0


"""
    FCAS_RAMPING_CVP_FACTOR

CVP factor (155) of AEMO's FCAS Joint Ramping constraint, item 20 of the *Schedule of Constraint
Violation Penalty Factors* v8.0. Prices [`FCASJointRampingSlack`](@ref).
"""
const FCAS_RAMPING_CVP_FACTOR = 155.0


"""
    FCAS_MAXAVAIL_CVP_FACTOR

CVP factor (155) of AEMO's FCAS MaxAvail constraint, item 19 of the *Schedule of Constraint
Violation Penalty Factors* v8.0. Prices [`FCASMaxAvailSlack`](@ref).
"""
const FCAS_MAXAVAIL_CVP_FACTOR = 155.0


"""
    FCAS_BDU_RAMPING_CVP_FACTOR

CVP factor (155) of AEMO's BDU Regulation FCAS SCADA Ramping constraint, item 21 of the
*Schedule of Constraint Violation Penalty Factors* v8.0. Prices [`FCASBDURampingSlack`](@ref).
"""
const FCAS_BDU_RAMPING_CVP_FACTOR = 155.0


"""
    _add_fcas_slack!(container, model, var_type, meta, names, time_steps, cvp_factor)

When `PSI.get_use_slacks(model)`, builds a non-negative slack variable of `var_type` per
`(name, t)` and prices it in the objective at `cvp_factor` times the Market Price Cap
([`_market_price_cap`](@ref)) for the interval, in `\$/MW` per dispatch interval.

# Returns
The slack variable container, or `nothing` when `use_slacks` is `false`.
"""
function _add_fcas_slack!(
        container::PSI.OptimizationContainer, model::PSI.ServiceModel, var_type, meta::AbstractString,
        names, time_steps, cvp_factor::Real,
    )
    PSI.get_use_slacks(model) || return nothing
    jm = PSI.get_jump_model(container)
    resolution = PSI.get_resolution(container)
    initial_time = PSI.get_initial_time(container)
    base_power = PSI.get_base_power(container)
    slack = PSI.add_variable_container!(container, var_type(), FCASService, names, time_steps; meta = meta)
    for t in time_steps
        mpc = _market_price_cap(container, model, initial_time + resolution * (t - 1))
        coefficient = base_power * interval_cost_coefficient(cvp_factor * mpc, resolution)
        for name in names
            slack[name, t] = JuMP.@variable(jm, base_name = "$(nameof(var_type))_$(meta)_{$name,$t}", lower_bound = 0.0)
            PSI.add_to_objective_invariant_expression!(container, slack[name, t] * coefficient)
        end
    end
    return slack
end


"""
    _add_fcas_max_avail_row!(jm, variable, slack, con, dname, t, max_avail)

Stores `variable - slack <= max_avail` in `con[dname, t]`, the MaxAvail limit of a capacity
variable: elastic when `slack` is a slack container, hard when it is `nothing`.

# Arguments
- `jm`: the JuMP model.
- `variable`, `slack`: the capacity variable and the slack container of [`FCASMaxAvailSlack`](@ref), or `nothing`.
- `con`: the [`FCASMaxAvailConstraint`](@ref) container the row is stored in, at `[dname, t]`.
- `max_avail`: the effective MaxAvail in per-unit, a number or a parameter.

# Returns
`nothing`.
"""
function _add_fcas_max_avail_row!(jm, variable, slack, con, dname, t, max_avail)
    con[dname, t] = JuMP.@constraint(jm, variable - _fcas_slack_term(slack, dname, t) <= max_avail)
    return
end


"""
    _fcas_slack_term(slack, name, t)

The slack variable of `slack` at `(name, t)`, or `0.0` when `slack` is `nothing` (`use_slacks = false`).
"""
_fcas_slack_term(slack, name, t) = isnothing(slack) ? 0.0 : slack[name, t]


"""
    _add_fcas_capacity_rows!(container, device, meta, capacity, upper_lhs, lower_lhs, slacks, cons, dname, t)

Builds `device`'s MaxAvail row and its two AEMO *FCAS Model in NEMDE* §6.2/§6.3 joint capacity
rows at `t` for the offer `meta` ([`_fcas_offer_meta`](@ref)) with capacity variable `capacity`:
`capacity - slack <= MaxAvail`, `upper_lhs + UpperSlopeCoeff × capacity - slack <= EnablementMax` and
`lower_lhs - LowerSlopeCoeff × capacity + slack >= EnablementMin`. The limits come from
[`FCASOfferLimitParameter`](@ref) and the slope coefficients from [`FCASUpperSlopeParameter`](@ref)
and [`FCASLowerSlopeParameter`](@ref).

# Arguments
- `slacks`: `(max, upper, lower)` slack containers, each `nothing` without slacks.
- `cons`: `(max, upper, lower)` constraint containers.

# Returns
`nothing`.
"""
function _add_fcas_capacity_rows!(
        container::PSI.OptimizationContainer, device::PSY.Device, meta::String, capacity, upper_lhs, lower_lhs,
        slacks, cons, dname::String, t::Int,
    )
    jm = PSI.get_jump_model(container)
    limits, multiplier = _fcas_parameter_refs(container, FCASOfferLimitParameter, device, meta)
    limit(field) = multiplier[dname, field, t] * limits[field, t]
    _add_fcas_max_avail_row!(jm, capacity, slacks.max, cons.max, dname, t, limit("max_avail"))
    cons.upper[dname, t] = JuMP.@constraint(
        jm, upper_lhs + capacity - _fcas_slack_term(slacks.upper, dname, t) <= limit("enablement_max"),
    )
    PSI.add_coefficient_target!(
        container, PSI.ParameterKey(FCASUpperSlopeParameter, typeof(device), meta), dname, t, cons.upper[dname, t], capacity, 1.0,
    )
    cons.lower[dname, t] = JuMP.@constraint(
        jm, lower_lhs - capacity + _fcas_slack_term(slacks.lower, dname, t) >= limit("enablement_min"),
    )
    PSI.add_coefficient_target!(
        container, PSI.ParameterKey(FCASLowerSlopeParameter, typeof(device), meta), dname, t, cons.lower[dname, t], capacity, -1.0,
    )
    return
end


"""
    _add_fcas_joint_ramping_constraints!(container, model, jm, devices, bid_type, name, time_steps)

Builds AEMO *FCAS Model in NEMDE* §6.1's [`FCASJointRampingConstraint`](@ref) for every
contributing `device` of a regulation `FCASService` named `name`: the unit's net energy
([`_fcas_net_energy_terms`](@ref)) combined with its [`FCASUnitRegulationTarget`](@ref) against
the `"joint_ramping"` field of its [`FCASRampingLimitParameter`](@ref) - the upper or lower form
depending on `bid_type` ([`_fcas_upper_regulation_service`](@ref)). Where §6.1 does not apply, the
parameter holds [`FCAS_INACTIVE_LIMIT_MW`](@ref) and the row never binds.

# Returns
`nothing`.
"""
function _add_fcas_joint_ramping_constraints!(
        container::PSI.OptimizationContainer, model::PSI.ServiceModel, jm, devices, bid_type::BidType,
        name::AbstractString, time_steps,
    )
    names = PSY.get_name.(devices)
    con = PSI.add_constraints_container!(
        container, FCASJointRampingConstraint(), FCASService, names, time_steps; meta = name,
    )
    target = PSI.get_expression(container, FCASUnitRegulationTarget(), FCASService, name)
    slack = _add_fcas_slack!(
        container, model, FCASJointRampingSlack, name, names, time_steps, FCAS_RAMPING_CVP_FACTOR,
    )
    for device in devices
        dname = PSY.get_name(device)
        ramping, multiplier = _fcas_parameter_refs(container, FCASRampingLimitParameter, device, string(bid_type))
        upper = bid_type == _fcas_upper_regulation_service(device)
        for t in time_steps
            lhs = JuMP.AffExpr(0.0)
            _add_fcas_net_energy_terms!(container, lhs, device, dname, t)
            limit = multiplier[dname, "joint_ramping", t] * ramping["joint_ramping", t]
            deficit = _fcas_slack_term(slack, dname, t)
            con[dname, t] = if upper
                JuMP.@constraint(jm, lhs + target[dname, t] - deficit <= limit)
            else
                JuMP.@constraint(jm, lhs - target[dname, t] + deficit >= limit)
            end
        end
    end
    return
end


"""
    _device_regulation_target(container, device, reg_bid_type, t) -> Union{Nothing, JuMP.AbstractJuMPScalar}

`device`'s [`FCASUnitRegulationTarget`](@ref) at `t` for the `reg_bid_type` regulation market it
belongs to, found via `PSY.get_services(device)`. `nothing` when `device` carries no such
service, or that service wasn't built under [`FCASMarket`](@ref) this run. Throws
`ArgumentError` if `device` belongs to more than one such service.

# Returns
`Union{Nothing, JuMP.AbstractJuMPScalar}`.
"""
function _device_regulation_target(container::PSI.OptimizationContainer, device::PSY.Device, reg_bid_type::BidType, t::Int)
    dname = PSY.get_name(device)
    targets = []
    for svc in PSY.get_services(device)
        svc isa FCASService || continue
        get_bid_type(svc) == reg_bid_type || continue
        name = PSY.get_name(svc)
        PSI.has_container_key(container, FCASUnitRegulationTarget, FCASService, name) || continue
        expr = PSI.get_expression(container, FCASUnitRegulationTarget(), FCASService, name)
        dname in axes(expr, 1) || continue
        push!(targets, expr[dname, t])
    end
    length(targets) > 1 && throw(
        ArgumentError(
            "FCASMarket: \"$dname\" contributes to $(length(targets)) $(string(reg_bid_type)) " *
                "FCASServices; a device can offer each FCAS market through only one.",
        ),
    )
    return isempty(targets) ? nothing : only(targets)
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
    unsupported = filter(!in((FCASJointCapacityConstraint, FCASJointRampingConstraint)), PSI.get_duals(model))
    isempty(unsupported) || throw(
        ArgumentError(
            "FCASMarket records duals for FCASJointCapacityConstraint and " *
                "FCASJointRampingConstraint only; got $(unsupported).",
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
    jm = PSI.get_jump_model(container)

    directions = Dict(PSY.get_name(d) => _fcas_direction(d, bid_type) for d in devices)
    _check_fcas_effective_series(container, devices, bid_type, directions)
    _add_fcas_offer_parameters!(container, sys, devices_template, devices, bid_type, directions)
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
            bound = _fcas_capacity_bound(container, device, bid_type, decremental)
            for t in time_steps
                var[dname, t] = JuMP.@variable(
                    jm, base_name = "FCASCapacityVariable_FCASService_$(name)_{$dname, $t}", lower_bound = 0.0,
                )
                _set_fcas_capacity_bound!(model, var[dname, t], bound)
                _add_fcas_energy_terms!(container, upper_lhs[dname, t], device, is_regulation, decremental, dname, t)
                _add_fcas_energy_terms!(container, lower_lhs[dname, t], device, is_regulation, decremental, dname, t)
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
        lhs = Dict(
            side => PSI.lazy_container_addition!(
                container, FCASJointCapacityLHS(), FCASService, both_names, time_steps; meta = "$(name)_$side",
            ) for side in ("gen_upper", "gen_lower", "load_upper", "load_lower")
        )
        for device in both_devices
            dname = PSY.get_name(device)
            gen_bound = _fcas_capacity_bound(container, device, bid_type, false)
            load_bound = _fcas_capacity_bound(container, device, bid_type, true)
            for t in time_steps
                gen_var[dname, t] = JuMP.@variable(
                    jm, base_name = "FCASSideCapacityVariable_FCASService_$(name)_gen_{$dname, $t}", lower_bound = 0.0,
                )
                _set_fcas_capacity_bound!(model, gen_var[dname, t], gen_bound)
                load_var[dname, t] = JuMP.@variable(
                    jm, base_name = "FCASSideCapacityVariable_FCASService_$(name)_load_{$dname, $t}", lower_bound = 0.0,
                )
                _set_fcas_capacity_bound!(model, load_var[dname, t], load_bound)
                for side in ("gen", "load"), bound in ("upper", "lower")
                    _add_fcas_side_energy_terms!(container, lhs["$(side)_$bound"][dname, t], device, Symbol(side), dname, t)
                end
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
    _fcas_offer_groups(name, devices, bid_type) -> Vector{NamedTuple}

The offers of an `FCASService` named `name`, grouped by the capacity variable container they sum
to: `(meta, variable, offers)` with `offers` a vector of `(device, decremental)`. Single-sided
devices form the group `meta = name` on [`FCASCapacityVariable`](@ref); a `PSY.Storage` device
bidding both sides of a regulation market has one offer in each of `"<name>_gen"` and
`"<name>_load"` on [`FCASSideCapacityVariable`](@ref).

# Returns
`Vector{NamedTuple{(:meta, :variable, :offers)}}`.
"""
function _fcas_offer_groups(name::AbstractString, devices, bid_type::BidType)
    directions = Dict(PSY.get_name(d) => _fcas_direction(d, bid_type) for d in devices)
    single = [(d, directions[PSY.get_name(d)] == :decremental) for d in devices if directions[PSY.get_name(d)] != :both]
    both = [d for d in devices if directions[PSY.get_name(d)] == :both]
    groups = NamedTuple[]
    isempty(single) || push!(groups, (meta = String(name), variable = FCASCapacityVariable(), offers = single))
    if !isempty(both)
        push!(groups, (meta = "$(name)_gen", variable = FCASSideCapacityVariable(), offers = [(d, false) for d in both]))
        push!(groups, (meta = "$(name)_load", variable = FCASSideCapacityVariable(), offers = [(d, true) for d in both]))
    end
    return groups
end


"""
    _fcas_band_labels(offers, bid_type) -> Vector{String}

Band labels `"1"` to `"n"`, `n` the most bands any offer in `offers` has over the whole of its
`"fcas_curve_..."` series, at least 1.

# Returns
`Vector{String}`.
"""
function _fcas_band_labels(offers, bid_type::BidType)
    n = 1
    for (device, decremental) in offers
        name = AustralianElectricityMarkets._fcas_series_name("fcas_curve", bid_type, decremental)
        curves = PSY.get_time_series_values(PSY.SingleTimeSeries, device, name)
        n = max(n, maximum(c -> length(PSY.get_y_coords(c)), curves))
    end
    return string.(1:n)
end


"""
    _set_fcas_band_prices!(container, prices, multiplier, meta, offers, bid_type, start_time)

Writes the band prices of each of `offers` (`(device, decremental)`) for `bid_type` from
`start_time` into the [`FCASBandPriceParameter`](@ref) array `prices` (`0.0` beyond the offered
bands) and adds each band's cost, price times `multiplier` times its [`FCASOfferBandVariable`](@ref)
of meta `meta`, to the variant objective.

# Returns
`nothing`.
"""
function _set_fcas_band_prices!(
        container::PSI.OptimizationContainer, prices, multiplier, meta::String, offers, bid_type::BidType, start_time::DateTime,
    )
    bands = PSI.get_variable(container, FCASOfferBandVariable(), FCASService, meta)
    labels = axes(prices)[2]
    horizon = length(PSI.get_time_steps(container))
    for (device, decremental) in offers
        dname = PSY.get_name(device)
        curves = get_fcas_offer_curve(device, bid_type, start_time, horizon; decremental = decremental)
        for (t, curve) in enumerate(curves)
            y = PSY.get_y_coords(curve)
            for (b, label) in enumerate(labels)
                prices[dname, label, t] = b <= length(y) ? y[b] : 0.0
                PSI.add_to_objective_variant_expression!(
                    container, prices[dname, label, t] * multiplier[dname, label, t] * bands[dname, label, t],
                )
            end
        end
    end
    return
end


"""
    _add_fcas_offer_bands!(container, group, bid_type)

For an [`_fcas_offer_groups`](@ref) `group`, adds one [`FCASOfferBandVariable`](@ref) per offer,
band and time step, each bounded by its [`FCASBandWidthParameter`](@ref) width, ties their sum to the
group's capacity variable, and prices them through an [`FCASBandPriceParameter`](@ref) of meta
`group.meta`. Band widths are per-unit of the system base and prices `\$/MW` per hour, so the price
multiplier is the system base power times the interval length in hours.

# Returns
`nothing`.
"""
function _add_fcas_offer_bands!(container::PSI.OptimizationContainer, group, bid_type::BidType)
    names = [PSY.get_name(d) for (d, _) in group.offers]
    labels = _fcas_band_labels(group.offers, bid_type)
    time_steps = PSI.get_time_steps(container)
    jm = PSI.get_jump_model(container)
    capacity = PSI.get_variable(container, group.variable, FCASService, group.meta)
    bands = PSI.add_variable_container!(
        container, FCASOfferBandVariable(), FCASService, names, labels, time_steps; meta = group.meta,
    )
    for (device, decremental) in group.offers
        dname = PSY.get_name(device)
        widths, multiplier = _fcas_parameter_refs(container, FCASBandWidthParameter, device, _fcas_offer_meta(bid_type, decremental))
        for t in time_steps
            for label in labels
                bands[dname, label, t] = JuMP.@variable(
                    jm, lower_bound = 0.0, base_name = "FCASOfferBandVariable_$(group.meta)_{$dname,$label,$t}",
                )
                JuMP.@constraint(jm, bands[dname, label, t] <= multiplier[dname, label, t] * widths[label, t])
            end
            JuMP.@constraint(jm, sum(bands[dname, label, t] for label in labels) == capacity[dname, t])
        end
    end
    price = PSI.add_param_container!(
        container, FCASBandPriceParameter(), FCASService, (FCASOfferBandVariable,),
        PSI.SOSStatusVariable.NO_VARIABLE, false, Float64, names, labels, time_steps; meta = group.meta,
    )
    prices, multiplier = PSI.get_parameter_array(price), PSI.get_multiplier_array(price)
    fill!(multiplier, PSI.get_base_power(container) * interval_hours(PSI.get_resolution(container)))
    _set_fcas_band_prices!(container, prices, multiplier, group.meta, group.offers, bid_type, PSI.get_initial_time(container))
    return
end


"""
    PSI.objective_function!(container, svc, model::PSI.ServiceModel{FCASService, FCASMarket})

Adds every contributing device's FCAS offer bands and their cost ([`_add_fcas_offer_bands!`](@ref)):
one offer per single-sided device, and one per side for a `PSY.Storage` device bidding both sides.

# Returns
`nothing`.
"""
function PSI.objective_function!(
        container::PSI.OptimizationContainer,
        svc::FCASService,
        model::PSI.ServiceModel{FCASService, FCASMarket},
    )
    devices = PSI.get_contributing_devices(model)
    isempty(devices) && return
    for group in _fcas_offer_groups(PSY.get_name(svc), devices, get_bid_type(svc))
        _add_fcas_offer_bands!(container, group, get_bid_type(svc))
    end
    return
end


# The `FCASService` and side (`nothing`, `"gen"` or `"load"`) of an `FCASBandPriceParameter` meta.
function _fcas_price_meta_service(sys::PSY.System, meta::String)
    svc = PSY.get_component(FCASService, sys, meta)
    isnothing(svc) || return svc, nothing
    for side in ("gen", "load")
        endswith(meta, "_$side") || continue
        svc = PSY.get_component(FCASService, sys, chopsuffix(meta, "_$side"))
        isnothing(svc) || return svc, side
    end
    throw(ArgumentError("No FCASService for the FCASBandPriceParameter meta \"$meta\"."))
end


"""
    PSI.update_container_parameter_values!(container, model, key::PSI.ParameterKey{FCASBandPriceParameter, FCASService}, input)

Simulation-step update of an [`FCASBandPriceParameter`](@ref): reads each offer's band prices for the
window at the model's current time and re-adds the band costs to the variant objective.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer, model::PSI.OperationModel,
        key::PSI.ParameterKey{FCASBandPriceParameter, FCASService}, ::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    PSI.is_synchronized(container) && error(
        "Cannot update FCASBandPriceParameter on a synchronized container; the band costs would be added twice.",
    )
    sys = PSI.get_system(model)
    svc, side = _fcas_price_meta_service(sys, key.meta)
    bid_type = get_bid_type(svc)
    prices = PSI.get_parameter_array(container, key)
    multiplier = PSI.get_parameter_multiplier_array(container, key)
    contributors = Dict(PSY.get_name(d) => d for d in PSY.get_contributing_devices(sys, svc))
    offers = map(axes(prices)[1]) do dname
        device = contributors[dname]
        (device, isnothing(side) ? _fcas_direction(device, bid_type) == :decremental : side == "load")
    end
    _set_fcas_band_prices!(container, prices, multiplier, key.meta, offers, bid_type, PSI.get_current_time(model))
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
    jm = PSI.get_jump_model(container)

    directions = Dict(PSY.get_name(d) => _fcas_direction(d, bid_type) for d in devices)
    both_devices = filter(d -> directions[PSY.get_name(d)] == :both, devices)
    single_devices = filter(d -> directions[PSY.get_name(d)] != :both, devices)
    single_names = PSY.get_name.(single_devices)
    both_names = PSY.get_name.(both_devices)

    # Contingency services carry the regulation targets: `RaiseReg` upper, `LowerReg` lower
    # (swapped for a load).
    if !is_regulation && !isempty(single_names)
        upper_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_upper")
        lower_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_lower")
        for device in single_devices
            dname = PSY.get_name(device)
            for t in time_steps
                upper_service = _fcas_upper_regulation_service(device)
                lower_service = upper_service == BidType.RAISEREG ? BidType.LOWERREG : BidType.RAISEREG
                upper_reg = _device_regulation_target(container, device, upper_service, t)
                isnothing(upper_reg) || JuMP.add_to_expression!(upper_lhs[dname, t], 1.0, upper_reg)
                lower_reg = _device_regulation_target(container, device, lower_service, t)
                isnothing(lower_reg) || JuMP.add_to_expression!(lower_lhs[dname, t], -1.0, lower_reg)
            end
        end
    end

    if !isempty(single_names)
        upper_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_upper")
        lower_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_lower")
        slacks = (
            max = _add_fcas_slack!(
                container, model, FCASMaxAvailSlack, "$(name)_maxavail", single_names, time_steps, FCAS_MAXAVAIL_CVP_FACTOR,
            ),
            upper = _add_fcas_slack!(
                container, model, FCASJointCapacitySlack, "$(name)_upper", single_names, time_steps, FCAS_CAPACITY_CVP_FACTOR,
            ),
            lower = _add_fcas_slack!(
                container, model, FCASJointCapacitySlack, "$(name)_lower", single_names, time_steps, FCAS_CAPACITY_CVP_FACTOR,
            ),
        )
        cons = (
            max = PSI.add_constraints_container!(
                container, FCASMaxAvailConstraint(), FCASService, single_names, time_steps; meta = "$(name)_maxavail",
            ),
            upper = PSI.add_constraints_container!(
                container, FCASJointCapacityConstraint(), FCASService, single_names, time_steps; meta = "$(name)_upper",
            ),
            lower = PSI.add_constraints_container!(
                container, FCASJointCapacityConstraint(), FCASService, single_names, time_steps; meta = "$(name)_lower",
            ),
        )
        cap_var = PSI.get_variable(container, FCASCapacityVariable(), FCASService, name)
        for device in single_devices
            dname = PSY.get_name(device)
            meta = _fcas_offer_meta(bid_type, directions[dname] == :decremental)
            for t in time_steps
                _add_fcas_capacity_rows!(
                    container, device, meta, cap_var[dname, t], upper_lhs[dname, t], lower_lhs[dname, t], slacks, cons, dname, t,
                )
            end
        end
    end

    if !isempty(both_names)
        for (side, decremental) in (("gen", false), ("load", true))
            upper_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_$(side)_upper")
            lower_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_$(side)_lower")
            slacks = (
                max = _add_fcas_slack!(
                    container, model, FCASMaxAvailSlack, "$(name)_$(side)_maxavail", both_names, time_steps, FCAS_MAXAVAIL_CVP_FACTOR,
                ),
                upper = _add_fcas_slack!(
                    container, model, FCASJointCapacitySlack, "$(name)_$(side)_upper", both_names, time_steps, FCAS_CAPACITY_CVP_FACTOR,
                ),
                lower = _add_fcas_slack!(
                    container, model, FCASJointCapacitySlack, "$(name)_$(side)_lower", both_names, time_steps, FCAS_CAPACITY_CVP_FACTOR,
                ),
            )
            cons = (
                max = PSI.add_constraints_container!(
                    container, FCASMaxAvailConstraint(), FCASService, both_names, time_steps; meta = "$(name)_$(side)_maxavail",
                ),
                upper = PSI.add_constraints_container!(
                    container, FCASJointCapacityConstraint(), FCASService, both_names, time_steps; meta = "$(name)_$(side)_upper",
                ),
                lower = PSI.add_constraints_container!(
                    container, FCASJointCapacityConstraint(), FCASService, both_names, time_steps; meta = "$(name)_$(side)_lower",
                ),
            )
            cap_var = PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(name)_$side")
            meta = _fcas_offer_meta(bid_type, decremental)
            for device in both_devices, t in time_steps
                dname = PSY.get_name(device)
                _add_fcas_capacity_rows!(
                    container, device, meta, cap_var[dname, t], upper_lhs[dname, t], lower_lhs[dname, t], slacks, cons, dname, t,
                )
            end
        end

        if is_regulation
            target = PSI.get_expression(container, FCASUnitRegulationTarget(), FCASService, name)
            con_ramp = PSI.add_constraints_container!(
                container, FCASBDURampingConstraint(), FCASService, both_names, time_steps; meta = name,
            )
            slack_ramp = _add_fcas_slack!(
                container, model, FCASBDURampingSlack, name, both_names, time_steps, FCAS_BDU_RAMPING_CVP_FACTOR,
            )
            for device in both_devices
                dname = PSY.get_name(device)
                ramping, multiplier = _fcas_parameter_refs(container, FCASRampingLimitParameter, device, string(bid_type))
                for t in time_steps
                    con_ramp[dname, t] = JuMP.@constraint(
                        jm, target[dname, t] - _fcas_slack_term(slack_ramp, dname, t) <=
                            multiplier[dname, "bdu_ramping", t] * ramping["bdu_ramping", t],
                    )
                end
            end
        end
    end

    if is_regulation
        _add_fcas_joint_ramping_constraints!(container, model, jm, devices, bid_type, name, time_steps)
    end

    if FCASJointCapacityConstraint in PSI.get_duals(model)
        for side in ("upper", "lower")
            isempty(single_names) || PSI.add_dual_container!(
                container, FCASJointCapacityConstraint, FCASService, single_names, time_steps; meta = "$(name)_$side",
            )
        end
        for side in ("gen_upper", "gen_lower", "load_upper", "load_lower")
            isempty(both_names) || PSI.add_dual_container!(
                container, FCASJointCapacityConstraint, FCASService, both_names, time_steps; meta = "$(name)_$side",
            )
        end
    end

    if is_regulation && FCASJointRampingConstraint in PSI.get_duals(model)
        names = PSY.get_name.(devices)
        PSI.add_dual_container!(container, FCASJointRampingConstraint, FCASService, names, time_steps; meta = name)
    end

    PSI.objective_function!(container, svc, model)
    return
end
