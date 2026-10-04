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
    _fcas_net_energy_terms(device) -> Vector{Tuple{DataType, Float64}}

The `PSI.VariableType`s (and their sign) making up `device`'s unit-level "Energy Dispatch
Target": the net `ActivePowerOutVariable - ActivePowerInVariable` for a `PSY.Storage` device,
`ActivePowerVariable` otherwise. Used wherever AEMO's formulation reads a single, signed
unit-level energy term rather than one bid side's own energy - AEMO *FCAS Model in NEMDE* §6.1's
joint ramping constraint and a `PSY.Storage` device's contingency FCAS.

# Returns
`Vector{Tuple{DataType, Float64}}` of `(VariableType, multiplier)` pairs.
"""
function _fcas_net_energy_terms(device::PSY.Device)
    device isa PSY.Storage && return [(PSI.ActivePowerOutVariable, 1.0), (PSI.ActivePowerInVariable, -1.0)]
    return [(PSI.ActivePowerVariable, 1.0)]
end

"""
    _fcas_energy_terms(device, is_regulation, decremental) -> Vector{Tuple{DataType, Float64}}

The `PSI.VariableType`s (and their sign) making up `device`'s FCAS "Energy Dispatch Target": for a
`PSY.Storage` device, the bid side's own energy on regulation (`ActivePowerOutVariable` for a
generation-side bid, `-ActivePowerInVariable` for a load-side one) and the net
([`_fcas_net_energy_terms`](@ref)) on contingency; `ActivePowerVariable` otherwise.
Throws `ArgumentError` for a decremental (`LOAD`-direction) bid on a non-`Storage` device.

# Returns
`Vector{Tuple{DataType, Float64}}` of `(VariableType, multiplier)` pairs.
"""
function _fcas_energy_terms(device::PSY.Device, is_regulation::Bool, decremental::Bool)
    if device isa PSY.Storage
        is_regulation || return _fcas_net_energy_terms(device)
        return decremental ? [(PSI.ActivePowerInVariable, -1.0)] : [(PSI.ActivePowerOutVariable, 1.0)]
    end
    decremental && throw(
        ArgumentError(
            "FCASMarket: \"$(PSY.get_name(device))\" ($(typeof(device))) has a decremental FCAS " *
                "bid but is not a `PSY.Storage` device; scheduled-load FCAS capacity is not modeled.",
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
    _fcas_series(container, devices_template, device, bid_type, decremental) -> (trapeziums, curves)

`device`'s FCAS trapezium and offer-curve series for `bid_type`, one entry per
`PSI.get_time_steps(container)`, read via
[`get_scaled_fcas_trapezium`](@ref)/[`get_fcas_offer_curve`](@ref). The trapezium is AEMO
*FCAS Model in NEMDE* §4's scaled/effective trapezium wherever `device` carries the scaling
input series ([`set_fcas_scaling_inputs!`](@ref)), with the AGC ramping capability taken over the
container's resolution, following [`_fcas_process`](@ref): every interval in dispatch; AGC
enablement and ramp scaling on the first interval only in 5-minute pre-dispatch; AGC enablement
scaling on the first interval only and no ramp scaling in 30-minute pre-dispatch. Otherwise it
is the bid trapezium unscaled.

# Returns
`(trapeziums::Vector{FCASTrapezium}, curves::Vector{PSY.PiecewiseStepData})`.
"""
function _fcas_series(
        container::PSI.OptimizationContainer, devices_template, device, bid_type::BidType, decremental::Bool,
    )
    initial_time = PSI.get_initial_time(container)
    horizon = length(PSI.get_time_steps(container))
    process = _fcas_process(container, devices_template, device)
    trapeziums = get_scaled_fcas_trapezium(
        device, bid_type, initial_time, horizon; decremental = decremental,
        resolution = PSI.get_resolution(container),
        agc_first_interval_only = process !== :dispatch, agc_ramp_scaling = process !== :predispatch,
    )
    return trapeziums, _fcas_offer_curves(container, device, bid_type, decremental)
end

"`device`'s FCAS offer curves for `bid_type`, one per `PSI.get_time_steps(container)` ([`get_fcas_offer_curve`](@ref))."
function _fcas_offer_curves(container::PSI.OptimizationContainer, device, bid_type::BidType, decremental::Bool)
    horizon = length(PSI.get_time_steps(container))
    return get_fcas_offer_curve(device, bid_type, PSI.get_initial_time(container), horizon; decremental = decremental)
end

"""
    _fcas_regulation_sides(container, devices_template, device, bid_type) -> (gen_trapeziums, gen_curves, load_trapeziums, load_curves)

A `PSY.Storage` device's generation-side and load-side trapezium and offer-curve series
([`_fcas_series`](@ref)) for a regulation `bid_type` it bids on both sides.

# Returns
`(gen_trapeziums::Vector{FCASTrapezium}, gen_curves::Vector{PSY.PiecewiseStepData}, load_trapeziums::Vector{FCASTrapezium}, load_curves::Vector{PSY.PiecewiseStepData})`.
"""
function _fcas_regulation_sides(container::PSI.OptimizationContainer, devices_template, device, bid_type::BidType)
    gen_trapeziums, gen_curves = _fcas_series(container, devices_template, device, bid_type, false)
    load_trapeziums, load_curves = _fcas_series(container, devices_template, device, bid_type, true)
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
    _fcas_enablement_inputs(container, devices_template, device) -> (initial_mw, availability, agc_status)

`device`'s per-interval §5 inputs: `InitialMW` ([`get_initial_mw`](@ref)), energy availability
([`get_storage_energy_max_avail`](@ref) as `(gen = ..., load = ...)` for a `PSY.Storage` device,
[`get_energy_availability`](@ref) otherwise) and AGC status ([`get_fcas_agc_status`](@ref)), each a
function of `t` returning `nothing` where unknown. Outside dispatch ([`_fcas_process`](@ref))
`InitialMW` and AGC status are known in the first interval only.

# Returns
`(initial_mw::Function, availability::Function, agc_status::Function)`.
"""
function _fcas_enablement_inputs(container::PSI.OptimizationContainer, devices_template, device::PSY.Device)
    initial_time = PSI.get_initial_time(container)
    horizon = length(PSI.get_time_steps(container))
    first_only = _fcas_process(container, devices_template, device) !== :dispatch
    initial_mw = get_initial_mw(device, initial_time, horizon)
    agc_status = get_fcas_agc_status(device, initial_time, horizon)
    telemetry(series, t) = (isnothing(series) || (first_only && t > 1)) ? nothing : series[t]
    availability_at = if device isa PSY.Storage
        storage = get_storage_energy_max_avail(device, initial_time, horizon)
        t -> _storage_energy_max_avail_at(storage, t)
    else
        avail = get_energy_availability(device, initial_time, horizon)
        t -> isnothing(avail) ? nothing : avail[t]
    end
    return (t -> telemetry(initial_mw, t), availability_at, t -> telemetry(agc_status, t))
end

"""
    _fcas_enabled_mask(container, devices_template, device, bid_type, decremental) -> Vector{Bool}

Per-interval [`_fcas_enabled`](@ref) for `device`'s one-directional `bid_type` bid, on the
[`_fcas_enablement_inputs`](@ref).

# Returns
`Vector{Bool}`, one entry per `PSI.get_time_steps(container)`.
"""
function _fcas_enabled_mask(
        container::PSI.OptimizationContainer, devices_template, device::PSY.Device, bid_type::BidType, decremental::Bool,
    )
    is_regulation = _is_regulation_service(bid_type)
    trapeziums, curves = _fcas_series(container, devices_template, device, bid_type, decremental)
    initial_mw, availability, agc_status = _fcas_enablement_inputs(container, devices_template, device)
    return map(PSI.get_time_steps(container)) do t
        _fcas_enabled(
            device, is_regulation, decremental, trapeziums[t], curves[t], availability(t), initial_mw(t), agc_status(t),
        )
    end
end

"""
    _fcas_both_sides_enabled_mask(container, devices_template, device, bid_type) -> (Vector{Bool}, Vector{Bool})

Per-interval [`_fcas_both_sides_enabled`](@ref) for a `PSY.Storage` device bidding regulation
`bid_type` on both sides, on the [`_fcas_enablement_inputs`](@ref).

# Returns
`(gen_enabled::Vector{Bool}, load_enabled::Vector{Bool})`.
"""
function _fcas_both_sides_enabled_mask(
        container::PSI.OptimizationContainer, devices_template, device::PSY.Device, bid_type::BidType,
    )
    gen_traps, gen_curves, load_traps, load_curves = _fcas_regulation_sides(container, devices_template, device, bid_type)
    initial_mw, availability, agc_status = _fcas_enablement_inputs(container, devices_template, device)
    flags = map(PSI.get_time_steps(container)) do t
        _fcas_both_sides_enabled(
            device, gen_traps[t], gen_curves[t], load_traps[t], load_curves[t], agc_status(t), initial_mw(t), availability(t),
        )
    end
    return first.(flags), last.(flags)
end

"""
    _fcas_agc_ramp_caps(container, devices_template, device, bid_type) -> Vector{Float64}

`device`'s AGC ramping capability on its regulation `bid_type` target, one entry per
`PSI.get_time_steps(container)`: the AGC ramping capability
([`get_fcas_agc_ramp_capability`](@ref)) over the container's resolution wherever
[`_fcas_agc_ramp_applies`](@ref), `0.0` (no cap) elsewhere or where the ramp rate is zero or
absent. Used by AEMO *FCAS Model in NEMDE* §6.1's joint ramping constraint (any device) and
§6.4's BDU SCADA ramping constraint (a `PSY.Storage` device bidding both sides).

# Returns
`Vector{Float64}`.
"""
function _fcas_agc_ramp_caps(container::PSI.OptimizationContainer, devices_template, device::PSY.Device, bid_type::BidType)
    time_steps = PSI.get_time_steps(container)
    ramp_cap = get_fcas_agc_ramp_capability(
        device, bid_type, PSI.get_initial_time(container), length(time_steps); resolution = PSI.get_resolution(container),
    )
    process = _fcas_process(container, devices_template, device)
    return [
        (isnothing(ramp_cap) || isnan(ramp_cap[t]) || !_fcas_agc_ramp_applies(process, t)) ? 0.0 : ramp_cap[t]
            for t in time_steps
    ]
end

"""
    _fcas_regulation_enabled_mask(container, devices_template, device, bid_type, direction) -> Vector{Bool}

`device`'s per-interval enablement for regulation `bid_type`, for the unit as a whole:
[`_fcas_enabled_mask`](@ref) for a single-sided `direction` (`:incremental`/`:decremental`), or,
for `direction == :both` (a `PSY.Storage` device bidding both sides), either side enabled
([`_fcas_both_sides_enabled_mask`](@ref)).

# Returns
`Vector{Bool}`, one entry per `PSI.get_time_steps(container)`.
"""
function _fcas_regulation_enabled_mask(
        container::PSI.OptimizationContainer, devices_template, device::PSY.Device, bid_type::BidType, direction::Symbol,
    )
    if direction == :both
        gen_enabled, load_enabled = _fcas_both_sides_enabled_mask(container, devices_template, device, bid_type)
        return gen_enabled .| load_enabled
    end
    return _fcas_enabled_mask(container, devices_template, device, bid_type, direction == :decremental)
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
    for name in names, t in time_steps
        slack[name, t] = JuMP.@variable(jm, base_name = "$(nameof(var_type))_$(meta)_{$name,$t}", lower_bound = 0.0)
        mpc = _market_price_cap(model, initial_time + resolution * (t - 1))
        coefficient = base_power * interval_cost_coefficient(cvp_factor * mpc, resolution)
        PSI.add_to_objective_invariant_expression!(container, slack[name, t] * coefficient)
    end
    return slack
end

"""
    _add_fcas_capacity_slack!(container, model, lhs, meta, names, time_steps, sign)

Merges a [`FCASJointCapacitySlack`](@ref) into the [`FCASJointCapacityLHS`](@ref) expression `lhs`
with multiplier `sign` (`-1.0` for an `<=` row, `+1.0` for a `>=` row). A no-op when the model has
`use_slacks = false`.

# Returns
`nothing`.
"""
function _add_fcas_capacity_slack!(container, model, lhs, meta, names, time_steps, sign::Float64)
    slack = _add_fcas_slack!(
        container, model, FCASJointCapacitySlack, meta, names, time_steps, FCAS_CAPACITY_CVP_FACTOR,
    )
    isnothing(slack) && return
    for name in names, t in time_steps
        JuMP.add_to_expression!(lhs[name, t], sign, slack[name, t])
    end
    return
end

"""
    _add_fcas_joint_ramping_constraints!(container, model, jm, devices, directions, devices_template, bid_type, name, time_steps)

Builds AEMO *FCAS Model in NEMDE* §6.1's [`FCASJointRampingConstraint`](@ref) for every
contributing `device` of a regulation `FCASService` named `name`: the unit's net energy
([`_fcas_net_energy_terms`](@ref)) combined with its [`FCASUnitRegulationTarget`](@ref) against
`InitialMW` plus or minus its AGC ramp capability ([`_fcas_agc_ramp_caps`](@ref)) - the upper
(`RAISEREG`) or lower (`LOWERREG`) form depending on `bid_type`. Builds a vacuous `0 <= 1` row at
`(dname, t)` wherever the ramp capability is zero, `InitialMW` is unknown at `t`, or the device
is not enabled for this service at `t` ([`_fcas_regulation_enabled_mask`](@ref)).

# Returns
`nothing`.
"""
function _add_fcas_joint_ramping_constraints!(
        container::PSI.OptimizationContainer, model::PSI.ServiceModel, jm, devices, directions::Dict{String, Symbol}, devices_template,
        bid_type::BidType, name::AbstractString, time_steps,
    )
    names = PSY.get_name.(devices)
    con = PSI.add_constraints_container!(
        container, FCASJointRampingConstraint(), FCASService, names, time_steps; meta = name,
    )
    target = PSI.get_expression(container, FCASUnitRegulationTarget(), FCASService, name)
    slack = _add_fcas_slack!(
        container, model, FCASJointRampingSlack, name, names, time_steps, FCAS_RAMPING_CVP_FACTOR,
    )
    initial_time = PSI.get_initial_time(container)
    horizon = length(time_steps)
    for device in devices
        dname = PSY.get_name(device)
        caps = _fcas_agc_ramp_caps(container, devices_template, device, bid_type)
        initial_mw = get_initial_mw(device, initial_time, horizon)
        enabled = _fcas_regulation_enabled_mask(container, devices_template, device, bid_type, directions[dname])
        for t in time_steps
            mw = isnothing(initial_mw) ? NaN : initial_mw[t]
            if iszero(caps[t]) || isnan(mw) || !enabled[t]
                con[dname, t] = JuMP.@constraint(jm, 0.0 <= 1.0)
                continue
            end
            lhs = JuMP.AffExpr(0.0)
            _add_fcas_net_energy_terms!(container, lhs, device, dname, t)
            deficit = isnothing(slack) ? 0.0 : slack[dname, t]
            con[dname, t] = if bid_type == BidType.RAISEREG
                JuMP.@constraint(jm, lhs + target[dname, t] - deficit <= mw + caps[t])
            else
                JuMP.@constraint(jm, lhs - target[dname, t] + deficit >= mw - caps[t])
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
    PSI.built_for_recurrent_solves(container) && throw(
        ArgumentError(
            "FCASMarket supports a standalone `DecisionModel` only: FCAS bids and the §5 " *
                "enablement pre-conditions are read once at build, so a `Simulation` would solve " *
                "every later step with the first step's FCAS data.",
        ),
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
            trapeziums, _ = _fcas_series(container, devices_template, device, bid_type, decremental)
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
            gen_traps, _, load_traps, _ = _fcas_regulation_sides(container, devices_template, device, bid_type)
            gen_enabled, load_enabled = _fcas_both_sides_enabled_mask(container, devices_template, device, bid_type)
            for t in time_steps
                gen_trap, load_trap = gen_traps[t], load_traps[t]
                gen_bound = gen_enabled[t] ? get_max_avail(gen_trap) : 0.0
                load_bound = load_enabled[t] ? get_max_avail(load_trap) : 0.0

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
    _add_fcas_offer_cost!(container, meta, dname, t, capacity_var, curve)

Adds `capacity_var`'s offer cost under `curve` (a `PSY.PiecewiseStepData` of cumulative-MW
bands with non-decreasing per-band prices) to the objective, via one bounded band variable per
band summing to `capacity_var`, named after the capacity variable's container `meta`. Band quantities are per-unit of the system base and prices are
`\$/MW` per hour, so each coefficient is scaled by `PSI.get_base_power(container)` and the
container's resolution in hours.

# Returns
`nothing`.
"""
function _add_fcas_offer_cost!(
        container::PSI.OptimizationContainer, meta::AbstractString, dname::AbstractString, t::Int,
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
        jm, [i = 1:n_bands], base_name = "FCASOfferBandVariable_$(meta)_{$dname, $t}",
        lower_bound = 0.0, upper_bound = x[i + 1] - x[i],
    )
    JuMP.@constraint(jm, sum(bands) == capacity_var)
    cost = base_power * sum(interval_cost_coefficient(y[i], resolution) * bands[i] for i in 1:n_bands)
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
            gen_curves = _fcas_offer_curves(container, device, bid_type, false)
            load_curves = _fcas_offer_curves(container, device, bid_type, true)
            gen_var = PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(name)_gen")
            load_var = PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(name)_load")
            for t in time_steps
                _add_fcas_offer_cost!(container, "$(name)_gen", dname, t, gen_var[dname, t], gen_curves[t])
                _add_fcas_offer_cost!(container, "$(name)_load", dname, t, load_var[dname, t], load_curves[t])
            end
        else
            curves = _fcas_offer_curves(container, device, bid_type, direction == :decremental)
            fcas_var = PSI.get_variable(container, FCASCapacityVariable(), FCASService, name)
            for t in time_steps
                _add_fcas_offer_cost!(container, name, dname, t, fcas_var[dname, t], curves[t])
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

        _add_fcas_capacity_slack!(container, model, upper_lhs, "$(name)_upper", single_names, time_steps, -1.0)
        _add_fcas_capacity_slack!(container, model, lower_lhs, "$(name)_lower", single_names, time_steps, 1.0)
        con_upper = PSI.add_constraints_container!(
            container, FCASJointCapacityConstraint(), FCASService, single_names, time_steps; meta = "$(name)_upper",
        )
        con_lower = PSI.add_constraints_container!(
            container, FCASJointCapacityConstraint(), FCASService, single_names, time_steps; meta = "$(name)_lower",
        )
        for device in single_devices
            dname = PSY.get_name(device)
            decremental = directions[dname] == :decremental
            trapeziums, _ = _fcas_series(container, devices_template, device, bid_type, decremental)
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
    end

    if !isempty(both_names)
        gen_upper_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_gen_upper")
        gen_lower_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_gen_lower")
        load_upper_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_load_upper")
        load_lower_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_load_lower")

        for (lhs, side, sign) in (
                (gen_upper_lhs, "gen_upper", -1.0), (gen_lower_lhs, "gen_lower", 1.0),
                (load_upper_lhs, "load_upper", -1.0), (load_lower_lhs, "load_lower", 1.0),
            )
            _add_fcas_capacity_slack!(container, model, lhs, "$(name)_$side", both_names, time_steps, sign)
        end
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
            gen_traps, _, load_traps, _ = _fcas_regulation_sides(container, devices_template, device, bid_type)
            gen_enabled, load_enabled = _fcas_both_sides_enabled_mask(container, devices_template, device, bid_type)
            for t in time_steps
                if !gen_enabled[t]
                    con_gen_upper[dname, t] = JuMP.@constraint(jm, 0.0 <= 1.0)
                    con_gen_lower[dname, t] = JuMP.@constraint(jm, 0.0 <= 1.0)
                else
                    gen_trap = gen_traps[t]
                    con_gen_upper[dname, t] = JuMP.@constraint(jm, gen_upper_lhs[dname, t] <= get_enablement_max(gen_trap))
                    con_gen_lower[dname, t] = JuMP.@constraint(jm, gen_lower_lhs[dname, t] >= get_enablement_min(gen_trap))
                end
                if !load_enabled[t]
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
                caps = _fcas_agc_ramp_caps(container, devices_template, device, bid_type)
                for t in time_steps
                    con_ramp[dname, t] = iszero(caps[t]) ?
                        JuMP.@constraint(jm, 0.0 <= 1.0) : JuMP.@constraint(jm, target[dname, t] <= caps[t])
                end
            end
        end
    end

    if is_regulation
        _add_fcas_joint_ramping_constraints!(container, model, jm, devices, directions, devices_template, bid_type, name, time_steps)
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
