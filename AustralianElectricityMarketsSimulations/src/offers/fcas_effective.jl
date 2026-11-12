"The other regulation service: `LOWERREG` for `RAISEREG` and `RAISEREG` for `LOWERREG`."
_other_regulation(bid_type::BidType) = bid_type == BidType.RAISEREG ? BidType.LOWERREG : BidType.RAISEREG


"""
    fcas_upper_regulation_service(device) -> BidType

The regulation service whose target enters `device`'s upper-slope (`<= EnablementMax`) FCAS rows:
`BidType.RAISEREG` for a generating unit, `BidType.LOWERREG` for a `PSY.ControllableLoad`, whose
energy axis is consumption so raising consumption lowers frequency (AEMO *FCAS Model in NEMDE*
§6.1, §6.2). The other regulation service enters the lower-slope rows.

# Arguments
- `device`: the device bidding FCAS.

# Returns
`BidType.RAISEREG` or `BidType.LOWERREG`.
"""
fcas_upper_regulation_service(::PSY.Device) = BidType.RAISEREG


fcas_upper_regulation_service(::PSY.ControllableLoad) = BidType.LOWERREG


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

`device`'s `bid_type` offer on `side` over `window` (`_FCASWindow`), read via
[`get_fcas_offer`](@ref). The trapezium is AEMO *FCAS Model in NEMDE* §4's scaled/effective
trapezium wherever `device` carries the scaling input series ([`set_unit_conditions!`](@ref)),
with the AGC ramping capability taken over the window's resolution at every interval. Otherwise it
is the bid trapezium unscaled.

# Returns
A `NEMFCASOffer`. Throws `ArgumentError` naming `device` when it carries no NEM unit data or has no bid
for `bid_type` on `side`.
"""
function _fcas_offer(window::_FCASWindow, device, bid_type::BidType, side::OfferSide)
    offer = get_fcas_offer(
        device, bid_type, side, window.initial_time, window.horizon; resolution = window.resolution,
    )
    isnothing(offer) && throw(
        ArgumentError("\"$(PSY.get_name(device))\" carries no NEM unit data, so it has no $(string(bid_type)) offer."),
    )
    return offer
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
    _fcas_preconditions(device, is_regulation, decremental, trap, curve, energy_max_avail, agc_status) -> Bool

The computable subset of AEMO's *FCAS Model in NEMDE* §5 enablement pre-conditions other than the
"stranded" one: `MaxAvail` positive; at least one priced band with positive quantity;
`EnablementMax` at or above `EnablementMin`; the sign pre-condition (`_fcas_sign_ok`); the
energy-maximum-availability pre-condition (`_fcas_energy_max_avail_ok`); and, for a regulation
service, `1 == agc_status` whenever `agc_status` is known. The caller ANDs the result with
[`fcas_state_stranded_ok`](@ref) or [`fcas_both_sides_stranded_ok`](@ref). The daily or profiled
energy pre-condition is not checked.

# Returns
`Bool`.
"""
function _fcas_preconditions(
        device::PSY.Device, is_regulation::Bool, decremental::Bool, trap::FCASTrapezium,
        curve::PSY.PiecewiseStepData,
        energy_max_avail::Union{Nothing, Float64, NamedTuple{(:gen, :load), Tuple{Float64, Float64}}},
        agc_status::Union{Nothing, Int},
    )
    get_max_avail(trap) > 0.0 || return false
    any(>(0.0), diff(PSY.get_x_coords(curve))) || return false
    get_enablement_max(trap) >= get_enablement_min(trap) || return false
    _fcas_sign_ok(device, is_regulation, decremental, trap) || return false
    _fcas_energy_max_avail_ok(device, is_regulation, decremental, trap, energy_max_avail) || return false
    is_regulation && !isnothing(agc_status) && agc_status == 0 && return false
    return true
end


"""
    _fcas_state_function(window, device) -> Function

`device`'s state over `window` as a function of `t`, in the `System`'s current display units, the
units the scaled FCAS trapeziums and AGC ramp capabilities are read in, or `nothing` where the
device publishes no starting output. A `NaN` starting output stays a state whose output is `NaN`,
which [`fcas_state_stranded_ok`](@ref) reads as outside every enablement span.

# Returns
A `Function` mapping `t` to a `Union{Nothing, NEMUnitState}`.
"""
function _fcas_state_function(window::_FCASWindow, device::PSY.Device)
    observed = AustralianElectricityMarkets.get_observed_state(device)
    initial = observed.initial_mw
    isnothing(initial) && return t -> nothing
    # The trapeziums carry the display-units multiplier, so the state must too, and in the same
    # arithmetic (`x / base * multiplier`) so a starting output at an enablement bound compares equal.
    base = PSY.get_system_base_power(device)
    multiplier = _fcas_units_multiplier(device)
    scaled(value, mode) = NEMUnitState(value / base * multiplier, mode)
    modes = _fcas_dispatch_modes(window, device, observed.dispatch_mode)
    initial isa IS.StaticTimeSeriesKey || return t -> scaled(initial, modes[t])
    values = IS.get_time_series_values(device, initial; start_time = window.initial_time, len = window.horizon)::Vector{Float64}
    return t -> scaled(values[t], modes[t])
end


# The observed dispatch mode of `device` over `window`, one per interval. A stamp with no published mode
# is 0, as `unit_state` seeds an unobserved stamp.
function _fcas_dispatch_modes(window::_FCASWindow, device::PSY.Device, dispatch_mode::Union{IS.StaticTimeSeriesKey, Int})
    dispatch_mode isa Int && return fill(dispatch_mode, window.horizon)
    raw = IS.get_time_series_values(device, dispatch_mode; start_time = window.initial_time, len = window.horizon)::Vector{Float64}
    return [isfinite(m) ? Int(m) : 0 for m in raw]
end


# Whether each interval of `window` is one in which `device` carries a fast-start inflexibility profile:
# a bid side's `T1` to `T4` profile with at least one positive value. A `FastStartProfile` held as a static
# bid value applies to every interval.
function _fcas_fast_start_flags(window::_FCASWindow, device::PSY.Device)
    flags = fill(false, window.horizon)
    cost = AustralianElectricityMarkets._nem_offer_cost(device)
    isnothing(cost) && return flags
    for bid in get_energy_bids(cost)
        isnothing(bid.fast_start_profile) && continue
        profiles = AustralianElectricityMarkets.bid_value(device, bid, :fast_start_profile, window.initial_time, window.horizon)
        for t in 1:window.horizon
            profile = profiles isa AbstractVector ? profiles[t] : profiles
            flags[t] |= any(>(0.0), (profile.t1, profile.t2, profile.t3, profile.t4))
        end
    end
    return flags
end


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
    _fcas_scaling_inputs(window, device) -> (availability, agc_status)

`device`'s energy availability (`_fcas_availability`) and AGC status ([`get_fcas_agc_status`](@ref))
over `window`, each a function of `t` returning `nothing` where unknown.

# Returns
`(availability::Function, agc_status::Function)`.
"""
function _fcas_scaling_inputs(window::_FCASWindow, device::PSY.Device)
    agc_status = get_fcas_agc_status(device, window.initial_time, window.horizon)
    telemetry(series, t) = isnothing(series) ? nothing : series[t]
    return _fcas_availability(window, device), t -> telemetry(agc_status, t)
end


"""
    _fcas_enabled_mask(window, device, bid_type, decremental; state = _fcas_state_function(window, device)) -> Vector{Bool}

Per-interval §5 enablement of `device`'s one-directional `bid_type` bid: the
`_fcas_preconditions`, ANDed with [`fcas_state_stranded_ok`](@ref) where the state is known.

# Returns
`Vector{Bool}`, one entry per interval of `window`.
"""
function _fcas_enabled_mask(
        window::_FCASWindow, device::PSY.Device, bid_type::BidType, decremental::Bool;
        state::Function = _fcas_state_function(window, device),
    )
    is_regulation = bid_type in FCAS_REGULATION_MARKETS
    (; trapeziums, curves) = _fcas_offer(window, device, bid_type, offer_side(decremental))
    availability, agc_status = _fcas_scaling_inputs(window, device)
    storage = device isa PSY.Storage
    return map(1:window.horizon) do t
        _fcas_preconditions(
            device, is_regulation, decremental, trapeziums[t], curves[t], availability(t), agc_status(t),
        ) || return false
        s = state(t)
        isnothing(s) && return true
        return fcas_state_stranded_ok(trapeziums[t], s; storage)
    end
end


"""
    _fcas_both_sides_enabled_mask(window, device, bid_type; state = _fcas_state_function(window, device)) -> (Vector{Bool}, Vector{Bool})

Per-interval §5 enablement of a `PSY.Storage` device bidding regulation `bid_type` on both sides:
each side's `_fcas_preconditions`, then, where the state is known,
[`fcas_both_sides_stranded_ok`](@ref).

# Returns
`(gen_enabled::Vector{Bool}, load_enabled::Vector{Bool})`.
"""
function _fcas_both_sides_enabled_mask(
        window::_FCASWindow, device::PSY.Device, bid_type::BidType;
        state::Function = _fcas_state_function(window, device),
    )
    gen, load = (_fcas_offer(window, device, bid_type, side) for side in (OfferSide.GEN, OfferSide.LOAD))
    availability, agc_status = _fcas_scaling_inputs(window, device)
    flags = map(1:window.horizon) do t
        gen_ok = _fcas_preconditions(device, true, false, gen.trapeziums[t], gen.curves[t], availability(t), agc_status(t))
        load_ok = _fcas_preconditions(device, true, true, load.trapeziums[t], load.curves[t], availability(t), agc_status(t))
        s = state(t)
        isnothing(s) && return (gen_ok, load_ok)
        return fcas_both_sides_stranded_ok(gen.trapeziums[t], load.trapeziums[t], gen_ok, load_ok, s)
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
    _fcas_regulation_enabled_mask(window, device, bid_type, direction; state = _fcas_state_function(window, device)) -> Vector{Bool}

`device`'s per-interval enablement for regulation `bid_type`, for the unit as a whole:
`_fcas_enabled_mask` for a single-sided `direction` (`INCREMENTAL` or `DECREMENTAL`), or,
for `direction == FCASBidDirection.BOTH` (a `PSY.Storage` device bidding both sides), either side enabled
(`_fcas_both_sides_enabled_mask`). `state` supplies the per-interval unit state the stranded
pre-condition reads.

# Returns
`Vector{Bool}`, one entry per interval of `window`.
"""
function _fcas_regulation_enabled_mask(
        window::_FCASWindow, device::PSY.Device, bid_type::BidType, direction::FCASBidDirection;
        state::Function = _fcas_state_function(window, device),
    )
    if direction == FCASBidDirection.BOTH
        gen_enabled, load_enabled = _fcas_both_sides_enabled_mask(window, device, bid_type; state)
        return gen_enabled .| load_enabled
    end
    return _fcas_enabled_mask(window, device, bid_type, direction == FCASBidDirection.DECREMENTAL; state)
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


"""
    fcas_effective_series_name(bid_type, decremental) -> String

Name of the [`set_effective_offers!`](@ref) series of one FCAS offer, `"fcas_effective_<BIDTYPE>"`
with `"_decremental"` appended for a decremental offer.

# Arguments
- `bid_type`: the FCAS market.
- `decremental`: whether the offer is decremental.

# Returns
A `String`.
"""
function fcas_effective_series_name(bid_type::BidType, decremental::Bool)
    return fcas_series_name("fcas_effective", bid_type, decremental)
end


"""
    fcas_ramping_series_name(bid_type) -> String

Name of the [`set_effective_offers!`](@ref) series of one regulation market, `"fcas_ramping_limits_<BIDTYPE>"`.

# Arguments
- `bid_type`: the regulation market.

# Returns
A `String`.
"""
function fcas_ramping_series_name(bid_type::BidType)
    return fcas_series_name("fcas_ramping_limits", bid_type)
end


"""
    fcas_offer_sides(direction) -> Tuple{Vararg{Bool}}

The `decremental` flag of each offer a device bidding in `direction` makes.

# Arguments
- `direction`: the [`FCASBidDirection`](@ref) of the device's offers.

# Returns
`(false,)` or `(true,)` for a single side, `(false, true)` for `BOTH`.
"""
function fcas_offer_sides(direction::FCASBidDirection)
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
    _fcas_effective_ramping(window, device, bid_type, direction, inactive; state = _fcas_state_function(window, device)) -> Vector{NTuple{2, Float64}}

`device`'s regulation ramping limits for `bid_type` over `window`, per-unit of the system base:
`(joint, bdu)` per interval. `joint` is the AEMO *FCAS Model in NEMDE* §6.1 right-hand side,
[`fcas_ramping_limit`](@ref) of the AGC ramping capability of `_fcas_ramp_rate_service` on the upper
form ([`fcas_upper_regulation_service`](@ref)) or the lower form, and `±inactive` wherever
[`fcas_ramping_active`](@ref) is false or the unit is not enabled for `bid_type`
(`_fcas_regulation_enabled_mask`), or the unit is exempt ([`fcas_joint_ramping_exempt`](@ref)) on a
fast-start interval. `bdu` is the §6.4 right-hand side of a `PSY.Storage` device
bidding both sides, its AGC ramping capability on `bid_type`, and `inactive` where that is zero or
for any other device.

# Returns
`Vector{NTuple{2, Float64}}`, one entry per interval of `window`.
"""
function _fcas_effective_ramping(
        window::_FCASWindow, device::PSY.Device, bid_type::BidType, direction::FCASBidDirection, inactive::Float64;
        state::Function = _fcas_state_function(window, device),
    )
    caps = _fcas_agc_ramp_caps(window, device, _fcas_ramp_rate_service(device, bid_type))
    enabled = _fcas_regulation_enabled_mask(window, device, bid_type, direction; state)
    fast_start = _fcas_fast_start_flags(window, device)
    upper = bid_type == fcas_upper_regulation_service(device)
    bdu_caps = direction == FCASBidDirection.BOTH ? _fcas_agc_ramp_caps(window, device, bid_type) : nothing
    return map(1:window.horizon) do t
        s = state(t)
        active = !isnothing(s) && enabled[t] && fcas_ramping_active(caps[t], s) && !fcas_joint_ramping_exempt(s, fast_start[t])
        joint = active ? fcas_ramping_limit(caps[t], upper, s) : (upper ? inactive : -inactive)
        bdu = (isnothing(bdu_caps) || iszero(bdu_caps[t])) ? inactive : bdu_caps[t]
        (joint, bdu)
    end
end


# Counts the derivations `_fcas_effective_values` computes, so a test can check that each is computed once per step.
const _FCAS_EVALUATIONS = Ref(0)


"""
    _fcas_effective_values(window, device, bid_type, direction, inactive; state = _fcas_state_function(window, device)) -> (offers, ramping)

`device`'s effective FCAS offers for `bid_type` over `window`: `offers` maps each offer's
`decremental` flag to its `_fcas_effective_offer` per interval, enabled by
`_fcas_both_sides_enabled_mask` for a `PSY.Storage` device's regulation bid on both sides and
by `_fcas_enabled_mask` otherwise; `ramping` is `_fcas_effective_ramping` for a
regulation market, `nothing` otherwise. `state` supplies the per-interval unit state the §5 and
§6.1 rules read.

# Returns
`(offers::Dict{Bool, Vector{NTuple{15, Float64}}}, ramping::Union{Nothing, Vector{NTuple{2, Float64}}})`.
"""
function _fcas_effective_values(
        window::_FCASWindow, device::PSY.Device, bid_type::BidType, direction::FCASBidDirection, inactive::Float64;
        state::Function = _fcas_state_function(window, device),
    )
    _FCAS_EVALUATIONS[] += 1
    regulation = bid_type in FCAS_REGULATION_MARKETS
    enabled::Dict{Bool, Vector{Bool}} = if direction == FCASBidDirection.BOTH && device isa PSY.Storage && regulation
        gen, load = _fcas_both_sides_enabled_mask(window, device, bid_type; state)
        Dict(false => gen, true => load)
    else
        Dict(dec => _fcas_enabled_mask(window, device, bid_type, dec; state) for dec in fcas_offer_sides(direction))
    end
    offers = Dict{Bool, Vector{NTuple{15, Float64}}}()
    for (decremental, mask) in enabled
        (; trapeziums, curves) = _fcas_offer(window, device, bid_type, offer_side(decremental))
        offers[decremental] = [_fcas_effective_offer(trapeziums[t], curves[t], mask[t], inactive) for t in 1:window.horizon]
    end
    regulation || return offers, nothing
    return offers, _fcas_effective_ramping(window, device, bid_type, direction, inactive; state)
end


"""
    _is_unpriced_unavailable(svc, device, bid_type) -> Bool

Whether `device` is unavailable and carries no stored offer curve for `svc` on one of its sides:
NEMDE-path units with no energy bids get no FCAS offer curve, and nothing reads their effective offer.
An available device without its curve is not skipped, so its missing data still fails.

# Returns
`Bool`.
"""
function _is_unpriced_unavailable(svc::FCASService, device::PSY.Device, bid_type::BidType)
    PSY.get_available(device) && return false
    sides = fcas_offer_sides(fcas_bid_direction(device, bid_type))
    return !all(dec -> !isnothing(AustralianElectricityMarkets._fcas_offer_key(device, bid_type, offer_side(dec))), sides)
end


"""
    _set_fcas_effective_offers!(sys)

Attaches the effective FCAS offers and regulation ramping limits of every device contributing to an
[`FCASService`](@ref), as the series described by [`set_effective_offers!`](@ref). Replaces existing series
of these names.

# Arguments
- `sys`: the `System` to add to.

# Returns
`nothing`.
"""
function _set_fcas_effective_offers!(sys::PSY.System)
    PSY.with_units_base(sys, "SYSTEM_BASE") do
        inactive = FCAS_INACTIVE_LIMIT_MW / PSY.get_base_power(sys)
        done = Set{Tuple{DataType, String, BidType}}()
        for svc in PSY.get_components(FCASService, sys)
            bid_type = get_bid_type(svc)
            for device in PSY.get_contributing_devices(sys, svc)
                key = (typeof(device), PSY.get_name(device), bid_type)
                key in done && continue
                push!(done, key)
                _is_unpriced_unavailable(svc, device, bid_type) && continue
                PSY.get_available(device) || continue
                _attach_fcas_effective_series!(sys, device, bid_type, inactive)
            end
        end
    end
    return
end


"""
    _attach_fcas_effective_series!(sys, device, bid_type, inactive)

Attaches `device`'s [`set_effective_offers!`](@ref) series for `bid_type`, computed over the
timestamps of its bid's trapezium series under the dispatch process (`_fcas_effective_values`).
No-op for a device without a `bid_type` FCAS bid.

# Returns
`nothing`.
"""
function _attach_fcas_effective_series!(sys::PSY.System, device::PSY.Device, bid_type::BidType, inactive::Float64)
    direction = fcas_bid_direction(device, bid_type)
    direction == FCASBidDirection.NONE && return
    side = direction == FCASBidDirection.DECREMENTAL ? OfferSide.LOAD : OfferSide.GEN
    trapezium = IS.get_name(_fcas_bid_inputs(device, bid_type, side).trapezium)
    stamps = PSY.get_time_series_timestamps(PSY.SingleTimeSeries, device, trapezium)
    resolution = IS.get_resolution(PSY.get_time_series(PSY.SingleTimeSeries, device, trapezium))
    window = _FCASWindow(first(stamps), length(stamps), resolution)
    offers, ramping = _fcas_effective_values(window, device, bid_type, direction, inactive)
    for (decremental, values) in offers
        replace_single_series!(sys, device, single_series(fcas_effective_series_name(bid_type, decremental), first(stamps), values, resolution))
    end
    isnothing(ramping) || replace_single_series!(sys, device, single_series(fcas_ramping_series_name(bid_type), first(stamps), ramping, resolution))
    return
end
