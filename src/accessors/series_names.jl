IS.@scoped_enum(OfferSide, GEN = 1, LOAD = 2)


@doc """
    OfferSide

The side of a unit's offer, as AEMO's `DIRECTION`: `GEN` for generation (incremental) and `LOAD`
for consumption (decremental). A storage device offers both; a scheduled load offers `LOAD` only.
""" OfferSide


"""
    offer_side(decremental::Bool) -> OfferSide

`OfferSide.LOAD` when `decremental`, `OfferSide.GEN` otherwise.
"""
offer_side(decremental::Bool) = decremental ? OfferSide.LOAD : OfferSide.GEN


"""
    side_suffix(side::OfferSide) -> String

The series-name suffix of `side`: `""` for `GEN` and `"_decremental"` for `LOAD`.
"""
side_suffix(side::OfferSide) = side == OfferSide.LOAD ? "_decremental" : ""


"""
    NEM_SERIES

Names of the per-device `SingleTimeSeries` the setters attach, by field:

- `initial_mw`: `DISPATCHLOAD.INITIALMW`, net MW, system-base per-unit.
- `ramp_up_rate`, `ramp_down_rate`: `DISPATCHLOAD.RAMPUPRATE`/`RAMPDOWNRATE`, system-base per-unit per minute.
- `availability`: `DISPATCHLOAD.AVAILABILITY`, system-base per-unit.
- `max_active_power`: the device's upper dispatch limit, a multiplier of its `max_active_power`.
- `uigf`: a semi-scheduled unit's `DISPATCHLOAD.UIGF`, read by its energy limit and FCAS trapezium
  scaling, system-base per-unit.
- `fcas_agc_status`: `DISPATCHLOAD.AGCSTATUS`, `0` or `1`.

Offer-side series are named by [`energy_max_avail_series_name`](@ref) and
[`fcas_series_name`](@ref).
"""
const NEM_SERIES = (
    initial_mw = "initial_mw",
    ramp_up_rate = "ramp_up_rate",
    ramp_down_rate = "ramp_down_rate",
    availability = "availability",
    max_active_power = "max_active_power",
    uigf = "uigf",
    fcas_agc_status = "fcas_agc_status",
)


"""
    energy_max_avail_series_name(side::OfferSide) -> String

Name of the series holding a device's energy offer `MAXAVAIL` on `side`, system-base per-unit.
"""
energy_max_avail_series_name(side::OfferSide) = "energy_max_avail" * side_suffix(side)


"""
    fcas_series_name(prefix, service[, side]) -> String

Name of the per-device FCAS time series `"<prefix>_<service>"`, suffixed by
[`side_suffix`](@ref) for an offer `side` (an `OfferSide`, or `decremental::Bool`).

# Arguments
- `prefix`: the series kind, such as `"fcas_trapezium"`, `"fcas_curve"` or `"fcas_agc_ramp_rate"`.
- `service`: the FCAS [`BidType`](@ref).
- `side`: the offer side; omitted for a series shared by both sides.

# Returns
A `String`.
"""
fcas_series_name(prefix::AbstractString, service::BidType) = "$(prefix)_$(string(service))"
fcas_series_name(prefix::AbstractString, service::BidType, side::OfferSide) = fcas_series_name(prefix, service) * side_suffix(side)
fcas_series_name(prefix::AbstractString, service::BidType, decremental::Bool) = fcas_series_name(prefix, service, offer_side(decremental))
