"The other regulation service: `LOWERREG` for `RAISEREG` and `RAISEREG` for `LOWERREG`."
_other_regulation(bid_type::BidType) = bid_type == BidType.RAISEREG ? BidType.LOWERREG : BidType.RAISEREG


"""
    _fcas_upper_regulation_service(device) -> BidType

The regulation service whose target enters `device`'s upper-slope (`<= EnablementMax`) FCAS rows:
`BidType.RAISEREG` for a generating unit, `BidType.LOWERREG` for a `PSY.ControllableLoad`, whose
energy axis is consumption so raising consumption lowers frequency (AEMO *FCAS Model in NEMDE*
§6.1, §6.2). The other regulation service enters the lower-slope rows.

# Returns
`BidType.RAISEREG` or `BidType.LOWERREG`.
"""
_fcas_upper_regulation_service(::PSY.Device) = BidType.RAISEREG


_fcas_upper_regulation_service(::PSY.ControllableLoad) = BidType.LOWERREG


"""
    _fcas_ramp_rate_service(device, bid_type) -> BidType

The regulation service whose AGC ramp-rate series bounds `device`'s joint ramping row for
`bid_type`: `bid_type` itself for a generating unit (`RAISEREG` reads the ramp-up rate, `LOWERREG`
the ramp-down rate), and the other service for a `PSY.ControllableLoad`, whose `LowerReg` row is
bounded by the SCADA ramp-up rate and `RaiseReg` row by the ramp-down rate (§6.1).

# Returns
`BidType.RAISEREG` or `BidType.LOWERREG`.
"""
_fcas_ramp_rate_service(::PSY.Device, bid_type::BidType) = bid_type


_fcas_ramp_rate_service(::PSY.ControllableLoad, bid_type::BidType) = _other_regulation(bid_type)


"""
    _FCASWindow(initial_time, horizon, resolution)

The intervals a device's FCAS inputs are read over: `horizon` dispatch intervals of `resolution`
from `initial_time`.

# Fields
- `initial_time::DateTime`: the first interval.
- `horizon::Int`: the number of intervals.
- `resolution::R`: the interval length.
"""
struct _FCASWindow{R <: Dates.Period}
    initial_time::DateTime
    horizon::Int
    resolution::R
end


"""
    _fcas_offer(window, device, bid_type, side) -> NEMFCASOffer

`device`'s `bid_type` offer on `side` over `window` ([`_FCASWindow`](@ref)), read via
[`get_fcas_offer`](@ref). The trapezium is AEMO *FCAS Model in NEMDE* §4's scaled/effective
trapezium wherever `device` carries the scaling input series ([`set_fcas_scaling_inputs!`](@ref)),
with the AGC ramping capability taken over the window's resolution at every interval. Otherwise it
is the bid trapezium unscaled.

# Returns
A `NEMFCASOffer`.
"""
function _fcas_offer(window::_FCASWindow, device, bid_type::BidType, side::OfferSide)
    return get_fcas_offer(
        device, bid_type, side, window.initial_time, window.horizon; resolution = window.resolution,
    )
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
_fcas_sign_ok(::PSY.Device, ::Bool, ::Bool, trap::FCASTrapezium) = get_enablement_max(trap) >= 0.0


function _fcas_sign_ok(::PSY.Storage, is_regulation::Bool, decremental::Bool, trap::FCASTrapezium)
    is_regulation || return true
    return decremental ? get_enablement_min(trap) <= 0.0 : get_enablement_max(trap) >= 0.0
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
_fcas_energy_max_avail_ok(::PSY.Device, ::Bool, ::Bool, ::FCASTrapezium, ::Nothing) = true


_fcas_energy_max_avail_ok(::PSY.Device, ::Bool, ::Bool, trap::FCASTrapezium, energy_max_avail::Float64) =
    energy_max_avail >= get_enablement_min(trap)


function _fcas_energy_max_avail_ok(
        device::PSY.Storage, is_regulation::Bool, decremental::Bool, trap::FCASTrapezium, ::Nothing,
    )
    static = (gen = PSY.get_output_active_power_limits(device).max, load = PSY.get_input_active_power_limits(device).max)
    return _fcas_energy_max_avail_ok(device, is_regulation, decremental, trap, static)
end


function _fcas_energy_max_avail_ok(
        ::PSY.Storage, is_regulation::Bool, decremental::Bool, trap::FCASTrapezium,
        energy_max_avail::NamedTuple{(:gen, :load), Tuple{Float64, Float64}},
    )
    load_ok = -energy_max_avail.load <= get_enablement_max(trap)
    gen_ok = energy_max_avail.gen >= get_enablement_min(trap)
    is_regulation && return decremental ? load_ok : gen_ok
    return load_ok && gen_ok
end


"""
    _fcas_enabled(device, is_regulation, decremental, trap, curve, energy_max_avail, initial_mw, agc_status; check_stranded = true) -> Bool

The computable subset of AEMO's *FCAS Model in NEMDE* §5 enablement pre-conditions: `MaxAvail`
positive; at least one priced band with positive quantity; `EnablementMax` at or above
`EnablementMin`; the sign pre-condition ([`_fcas_sign_ok`](@ref)); the energy-maximum-availability
pre-condition ([`_fcas_energy_max_avail_ok`](@ref)); when `check_stranded` and `initial_mw` is
known, the "stranded" pre-condition (`initial_mw` for a `PSY.Storage` device, `Max[initial_mw,
0]` otherwise, inside `[EnablementMin, EnablementMax]`); and, for a regulation service, `1 ==
agc_status` whenever `agc_status` is known. The daily or profiled energy pre-condition is not
checked.

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
        get_enablement_min(trap) <= _fcas_stranded_point(device, initial_mw) <= get_enablement_max(trap) || return false
    end
    is_regulation && !isnothing(agc_status) && agc_status == 0 && return false
    return true
end


# The output §5's "stranded" pre-condition checks: `initial_mw` for storage, `Max[initial_mw, 0]` otherwise.
_fcas_stranded_point(::PSY.Device, initial_mw::Float64) = max(initial_mw, 0.0)


_fcas_stranded_point(::PSY.Storage, initial_mw::Float64) = initial_mw


"""
    _fcas_availability(window, device) -> Function

`device`'s energy availability over `window` as a function of `t`, `nothing` where unknown:
[`get_storage_energy_max_avail`](@ref) as `(gen = ..., load = ...)` for a `PSY.Storage` device,
[`get_energy_availability`](@ref) otherwise.
"""
function _fcas_availability(window::_FCASWindow, device::PSY.Device)
    avail = get_energy_availability(device, window.initial_time, window.horizon)
    return t -> isnothing(avail) ? nothing : avail[t]
end


function _fcas_availability(window::_FCASWindow, device::PSY.Storage)
    avail = get_storage_energy_max_avail(device, window.initial_time, window.horizon)
    return t -> isnothing(avail) ? nothing : (gen = avail.gen[t], load = avail.load[t])
end


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

`device`'s per-interval §5 inputs over `window` ([`_FCASWindow`](@ref)): `InitialMW`
([`get_initial_mw`](@ref)), energy availability ([`_fcas_availability`](@ref)) and AGC status ([`get_fcas_agc_status`](@ref)), each a function of `t` returning `nothing` where
unknown.

# Returns
`(initial_mw::Function, availability::Function, agc_status::Function)`.
"""
function _fcas_enablement_inputs(window::_FCASWindow, device::PSY.Device)
    initial_mw = get_initial_mw(device, window.initial_time, window.horizon)
    agc_status = get_fcas_agc_status(device, window.initial_time, window.horizon)
    telemetry(series, t) = isnothing(series) ? nothing : series[t]
    return (t -> telemetry(initial_mw, t), _fcas_availability(window, device), t -> telemetry(agc_status, t))
end


"""
    _fcas_enabled_mask(window, device, bid_type, decremental) -> Vector{Bool}

Per-interval [`_fcas_enabled`](@ref) for `device`'s one-directional `bid_type` bid, on the
[`_fcas_enablement_inputs`](@ref) over `window`.

# Returns
`Vector{Bool}`, one entry per interval of `window`.
"""
function _fcas_enabled_mask(window::_FCASWindow, device::PSY.Device, bid_type::BidType, decremental::Bool)
    is_regulation = bid_type in FCAS_REGULATION_MARKETS
    (; trapeziums, curves) = _fcas_offer(window, device, bid_type, offer_side(decremental))
    initial_mw, availability, agc_status = _fcas_enablement_inputs(window, device)
    return map(1:window.horizon) do t
        _fcas_enabled(
            device, is_regulation, decremental, trapeziums[t], curves[t], availability(t), initial_mw(t), agc_status(t),
        )
    end
end


"""
    _fcas_both_sides_enabled_mask(window, device, bid_type) -> (Vector{Bool}, Vector{Bool})

Per-interval [`_fcas_both_sides_enabled`](@ref) for a `PSY.Storage` device bidding regulation
`bid_type` on both sides, on the [`_fcas_enablement_inputs`](@ref) over `window`.

# Returns
`(gen_enabled::Vector{Bool}, load_enabled::Vector{Bool})`.
"""
function _fcas_both_sides_enabled_mask(window::_FCASWindow, device::PSY.Device, bid_type::BidType)
    gen, load = (_fcas_offer(window, device, bid_type, side) for side in (OfferSide.GEN, OfferSide.LOAD))
    initial_mw, availability, agc_status = _fcas_enablement_inputs(window, device)
    flags = map(1:window.horizon) do t
        _fcas_both_sides_enabled(
            device, gen.trapeziums[t], gen.curves[t], load.trapeziums[t], load.curves[t], agc_status(t), initial_mw(t), availability(t),
        )
    end
    return first.(flags), last.(flags)
end


"""
    _fcas_agc_ramp_caps(window, device, bid_type) -> Vector{Float64}

`device`'s AGC ramping capability on its regulation `bid_type` target, one entry per interval of
`window`: the AGC ramping capability ([`get_fcas_agc_ramp_capability`](@ref)) over the window's
resolution, or `0.0` (no cap) where the ramp rate is zero or absent. Used by AEMO *FCAS Model in NEMDE* §6.1's joint ramping constraint (any
device) and §6.4's BDU SCADA ramping constraint (a `PSY.Storage` device bidding both sides).

# Returns
`Vector{Float64}`.
"""
function _fcas_agc_ramp_caps(window::_FCASWindow, device::PSY.Device, bid_type::BidType)
    ramp_cap = get_fcas_agc_ramp_capability(
        device, bid_type, window.initial_time, window.horizon; resolution = window.resolution,
    )
    return [
        (isnothing(ramp_cap) || isnan(ramp_cap[t])) ? 0.0 : ramp_cap[t]
            for t in 1:window.horizon
    ]
end


"""
    _fcas_regulation_enabled_mask(window, device, bid_type, direction) -> Vector{Bool}

`device`'s per-interval enablement for regulation `bid_type`, for the unit as a whole:
[`_fcas_enabled_mask`](@ref) for a single-sided `direction` (`INCREMENTAL` or `DECREMENTAL`), or,
for `direction == FCASBidDirection.BOTH` (a `PSY.Storage` device bidding both sides), either side enabled
([`_fcas_both_sides_enabled_mask`](@ref)).

# Returns
`Vector{Bool}`, one entry per interval of `window`.
"""
function _fcas_regulation_enabled_mask(window::_FCASWindow, device::PSY.Device, bid_type::BidType, direction::FCASBidDirection)
    if direction == FCASBidDirection.BOTH
        gen_enabled, load_enabled = _fcas_both_sides_enabled_mask(window, device, bid_type)
        return gen_enabled .| load_enabled
    end
    return _fcas_enabled_mask(window, device, bid_type, direction == FCASBidDirection.DECREMENTAL)
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
function _fcas_effective_series_name(bid_type::BidType, decremental::Bool)
    return fcas_series_name("fcas_effective", bid_type, decremental)
end


"`\"fcas_ramping_limits_<BIDTYPE>\"`, the [`set_fcas_effective_offers!`](@ref) series of one regulation market."
function _fcas_ramping_series_name(bid_type::BidType)
    return fcas_series_name("fcas_ramping_limits", bid_type)
end


"The `decremental` flag of each offer a device bidding in `direction` makes: one, or two for `BOTH`."
function _fcas_offer_sides(direction::FCASBidDirection)
    direction == FCASBidDirection.BOTH && return (false, true)
    return (direction == FCASBidDirection.DECREMENTAL,)
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
function _fcas_effective_ramping(window::_FCASWindow, device::PSY.Device, bid_type::BidType, direction::FCASBidDirection, inactive::Float64)
    caps = _fcas_agc_ramp_caps(window, device, _fcas_ramp_rate_service(device, bid_type))
    initial_mw = get_initial_mw(device, window.initial_time, window.horizon)
    enabled = _fcas_regulation_enabled_mask(window, device, bid_type, direction)
    upper = bid_type == _fcas_upper_regulation_service(device)
    bdu_caps = direction == FCASBidDirection.BOTH ? _fcas_agc_ramp_caps(window, device, bid_type) : nothing
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
function _fcas_effective_values(window::_FCASWindow, device::PSY.Device, bid_type::BidType, direction::FCASBidDirection, inactive::Float64)
    regulation = bid_type in FCAS_REGULATION_MARKETS
    enabled = if direction == FCASBidDirection.BOTH && device isa PSY.Storage && regulation
        gen, load = _fcas_both_sides_enabled_mask(window, device, bid_type)
        Dict(false => gen, true => load)
    else
        Dict(dec => _fcas_enabled_mask(window, device, bid_type, dec) for dec in _fcas_offer_sides(direction))
    end
    offers = Dict{Bool, Vector{NTuple{15, Float64}}}()
    for (decremental, mask) in enabled
        (; trapeziums, curves) = _fcas_offer(window, device, bid_type, offer_side(decremental))
        offers[decremental] = [_fcas_effective_offer(trapeziums[t], curves[t], mask[t], inactive) for t in 1:window.horizon]
    end
    regulation || return offers, nothing
    return offers, _fcas_effective_ramping(window, device, bid_type, direction, inactive)
end


"""
    set_fcas_effective_offers!(sys)

Attaches, for every device contributing to an [`FCASService`](@ref), the effective FCAS offer
NEMDE dispatches against in each interval (AEMO *FCAS Model in NEMDE* §4 scaling and §5 enablement
pre-conditions), on the timestamps of the device's `"fcas_trapezium_<BIDTYPE>[_decremental]"`
series, per-unit of the system base:

- `"fcas_effective_<BIDTYPE>[_decremental]"`, one `NTuple{15, Float64}` per interval:
  `(MaxAvail, EnablementMin, EnablementMax, UpperSlopeCoeff, LowerSlopeCoeff, w1, ..., w10)` of the
  scaled trapezium and the offer's band widths, padded with zero widths. An offer not enabled has
  zero `MaxAvail`, slopes and widths and enablement limits `∓FCAS_INACTIVE_LIMIT_MW`.
- `"fcas_ramping_limits_<BIDTYPE>"` for a regulation market, one `NTuple{2, Float64}` per interval:
  the §6.1 joint ramping right-hand side, `+FCAS_INACTIVE_LIMIT_MW` for the upper form and
  `-FCAS_INACTIVE_LIMIT_MW` for the lower form where it does not apply, and, for a `Storage` device
  bidding both sides, the §6.4 SCADA ramping right-hand side, `+FCAS_INACTIVE_LIMIT_MW` where it
  does not apply.

Values follow the dispatch process: AGC scaling, AGC status and `InitialMW` apply at every interval.
Existing series of these names are replaced. Call it after [`set_fcas_bids!`](@ref),
[`set_fcas_scaling_inputs!`](@ref), [`set_market_bids!`](@ref), [`set_nem_dispatch_limits!`](@ref)
and [`add_fcas_services!`](@ref), and before `transform_single_time_series!`; [`FCASMarket`](@ref)
requires these series.

# Arguments
- `sys`: the `System` to add to.

# Returns
`nothing`.
"""
function set_fcas_effective_offers!(sys::PSY.System)
    PSY.with_units_base(sys, "SYSTEM_BASE") do
        inactive = FCAS_INACTIVE_LIMIT_MW / PSY.get_base_power(sys)
        done = Set{Tuple{DataType, String, BidType}}()
        for svc in PSY.get_components(FCASService, sys)
            bid_type = get_bid_type(svc)
            for device in PSY.get_contributing_devices(sys, svc)
                key = (typeof(device), PSY.get_name(device), bid_type)
                key in done && continue
                push!(done, key)
                _attach_fcas_effective_series!(sys, device, bid_type, inactive)
            end
        end
    end
    return
end


"""
    _attach_fcas_effective_series!(sys, device, bid_type, inactive)

Attaches `device`'s [`set_fcas_effective_offers!`](@ref) series for `bid_type`, computed over the
timestamps of its trapezium series under the dispatch process ([`_fcas_effective_values`](@ref)).
No-op for a device without a `bid_type` trapezium series.

# Returns
`nothing`.
"""
function _attach_fcas_effective_series!(sys::PSY.System, device::PSY.Device, bid_type::BidType, inactive::Float64)
    direction = fcas_bid_direction(device, bid_type)
    direction == FCASBidDirection.NONE && return
    trapezium = fcas_series_name("fcas_trapezium", bid_type, direction == FCASBidDirection.DECREMENTAL)
    stamps = PSY.get_time_series_timestamps(PSY.SingleTimeSeries, device, trapezium)
    resolution = IS.get_resolution(PSY.get_time_series(PSY.SingleTimeSeries, device, trapezium))
    window = _FCASWindow(first(stamps), length(stamps), resolution)
    offers, ramping = _fcas_effective_values(window, device, bid_type, direction, inactive)
    for (decremental, values) in offers
        replace_single_series!(sys, device, single_series(_fcas_effective_series_name(bid_type, decremental), first(stamps), values, resolution))
    end
    isnothing(ramping) || replace_single_series!(sys, device, single_series(_fcas_ramping_series_name(bid_type), first(stamps), ramping, resolution))
    return
end
