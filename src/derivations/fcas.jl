"The other regulation service: `LOWERREG` for `RAISEREG` and `RAISEREG` for `LOWERREG`."
_other_regulation(bid_type::BidType) = bid_type == BidType.RAISEREG ? BidType.LOWERREG : BidType.RAISEREG


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
    fcas_preconditions_ok(trap, total_band_width, energy_max_avail_gen, energy_max_avail_load, agc_status, is_regulation, decremental, storage) -> Bool

The computable subset of AEMO's *FCAS Model in NEMDE* §5 enablement pre-conditions other than the
"stranded" one ([`fcas_state_stranded_ok`](@ref) or [`fcas_both_sides_stranded_ok`](@ref), which the
caller ANDs in): `MaxAvail` positive; at least one priced band with positive quantity; `EnablementMax`
at or above `EnablementMin`; the sign pre-condition; the energy-maximum-availability pre-condition; and,
for a regulation service, `agc_status` other than `0`. The daily or profiled energy pre-condition is
not checked.

The sign pre-condition requires `EnablementMax >= 0` for a non-storage device, and for a storage device
bidding regulation on the generation side. A storage device's load-side regulation requires
`EnablementMin <= 0`, and its contingency FCAS carries no sign requirement.

The energy pre-condition for a non-storage device is `energy_max_avail_gen >= EnablementMin`. For a
storage device, load-side regulation requires `-energy_max_avail_load <= EnablementMax`,
generation-side regulation requires `energy_max_avail_gen >= EnablementMin`, and contingency FCAS
requires both. An availability of `Inf` is no limit and passes, and a `NaN` availability is data that
fails its comparison. For a storage device the caller substitutes the static output or input rating
when no availability is published.

`total_band_width > 0` assumes the band widths are non-negative.

# Arguments
- `trap`: the effective FCAS trapezium of the interval.
- `total_band_width`: the sum of the offer's non-negative band widths, MW; positive when a band carries quantity.
- `energy_max_avail_gen`: the energy availability, MW, `Inf` where there is no limit; for a storage device the generation-side `MAXAVAIL`.
- `energy_max_avail_load`: the storage device's load-side `MAXAVAIL`, MW, `Inf` where there is no limit; unused for other devices.
- `agc_status`: the AGC status of the interval; `-1` where unknown.
- `is_regulation`: whether the service is a regulation market.
- `decremental`: whether the offer is the load side of the device.
- `storage`: whether the device is a `PowerSystems.Storage`.

# Returns
`Bool`.
"""
function fcas_preconditions_ok(
        trap::FCASTrapezium, total_band_width::Float64, energy_max_avail_gen::Float64,
        energy_max_avail_load::Float64, agc_status::Int, is_regulation::Bool, decremental::Bool, storage::Bool,
    )
    get_max_avail(trap) > 0.0 || return false
    total_band_width > 0.0 || return false
    get_enablement_max(trap) >= get_enablement_min(trap) || return false
    sign_ok = if storage
        !is_regulation || (decremental ? get_enablement_min(trap) <= 0.0 : get_enablement_max(trap) >= 0.0)
    else
        get_enablement_max(trap) >= 0.0
    end
    sign_ok || return false
    energy_ok = if storage
        load_ok = -energy_max_avail_load <= get_enablement_max(trap)
        gen_ok = energy_max_avail_gen >= get_enablement_min(trap)
        is_regulation ? (decremental ? load_ok : gen_ok) : (load_ok && gen_ok)
    else
        energy_max_avail_gen >= get_enablement_min(trap)
    end
    energy_ok || return false
    return !(is_regulation && agc_status == 0)
end


"""
    fcas_effective_offer(trap, band_widths, enabled, inactive) -> NTuple{15, Float64}

One interval of an FCAS offer's effective series, in MW:
`(MaxAvail, EnablementMin, EnablementMax, UpperSlopeCoeff, LowerSlopeCoeff, w1, ..., w10)`, the first
three and the band widths in MW and the two slope coefficients dimensionless, of the effective
trapezium `trap` and the band widths `band_widths`, zero-padded to [`FCAS_BAND_COUNT`](@ref).
An offer that is not `enabled` has zero `MaxAvail`, slopes and widths, and enablement limits
`-inactive` and `inactive`.

# Arguments
- `trap`: the effective FCAS trapezium of the interval, in MW.
- `band_widths`: the band widths of the offer, MW, zero-padded to `FCAS_BAND_COUNT`.
- `enabled`: whether the offer is enabled in the interval.
- `inactive`: the enablement limit of a disabled offer, MW (`FCAS_INACTIVE_LIMIT_MW`).

# Returns
`NTuple{15, Float64}`.
"""
function fcas_effective_offer(
        trap::FCASTrapezium, band_widths::NTuple{FCAS_BAND_COUNT, Float64}, enabled::Bool, inactive::Float64,
    )::NTuple{15, Float64}
    enabled || return (0.0, -inactive, inactive, 0.0, 0.0, ntuple(_ -> 0.0, FCAS_BAND_COUNT)...)
    return (
        get_max_avail(trap), get_enablement_min(trap), get_enablement_max(trap),
        get_upper_slope_coeff(trap), get_lower_slope_coeff(trap), band_widths...,
    )
end


"""
    fcas_ramping_limits(capability, bdu_capability, enabled, upper, fast_start, inactive, state::NEMUnitState) -> NTuple{2, Float64}

One interval of a regulation market's ramping limits, in MW: `(joint, bdu)`.
`joint` is the AEMO *FCAS Model in NEMDE* §6.1 right-hand side, [`fcas_ramping_limit`](@ref) of the
AGC ramping `capability` on the upper or lower form, and `±inactive` where the row is inactive: the
capability is zero or absent, the unit is not `enabled` for the market, or the unit is exempt on a
fast-start interval ([`fcas_joint_ramping_exempt`](@ref)). `bdu` is the §6.4 right-hand side of a
`PSY.Storage` device bidding both sides, its AGC ramping capability on the market, and `inactive`
where that is zero. A caller with an unknown starting output writes `±inactive` itself.

# Arguments
- `capability`: the AGC ramping capability over the interval, MW; `0.0` where the ramp rate is absent.
- `bdu_capability`: the AGC ramping capability of a device bidding both sides, MW; `0.0` otherwise. Must not be `NaN`: callers clean a `NaN` capability to `0.0`.
- `enabled`: whether the unit is enabled for the market in the interval.
- `upper`: whether the joint limit is the upper form.
- `fast_start`: whether the unit carries a fast-start inflexibility profile in the interval.
- `inactive`: the inactive limit, MW (`FCAS_INACTIVE_LIMIT_MW`).
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.

# Returns
`NTuple{2, Float64}`.
"""
function fcas_ramping_limits(
        capability::Float64, bdu_capability::Float64, enabled::Bool, upper::Bool, fast_start::Bool,
        inactive::Float64, state::NEMUnitState,
    )::NTuple{2, Float64}
    active = enabled && fcas_ramping_active(capability, state) && !fcas_joint_ramping_exempt(state, fast_start)
    joint = active ? fcas_ramping_limit(capability, upper, state) : (upper ? inactive : -inactive)
    bdu = iszero(bdu_capability) ? inactive : bdu_capability
    return (joint, bdu)
end
