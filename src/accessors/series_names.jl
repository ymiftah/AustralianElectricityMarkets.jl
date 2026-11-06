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

- `ramp_up_rate`, `ramp_down_rate`: the dispatch ramp rates the formulation reads, system-base per-unit
  per minute, derived by AEMSim from the telemetry ramp limits.
- `max_active_power`: the device's upper dispatch limit, a multiplier of its `max_active_power`.
- `fixed_load`: a unit's participant fixed loading, net injection in system-base per-unit.
- `fixed_load_invoked`: `1` at the intervals a fixed loading applies, `0` elsewhere.
- `from_to_flow_limit`, `to_from_flow_limit`: an interchange's per-interval flow limits, system-base
  per-unit.
- `loss_demand_coefficient`: an interchange's demand term of its loss factor.

The unit condition series are named by [`NEM_TELEMETRY_SERIES`](@ref) and [`NEM_OBSERVED_SERIES`](@ref),
and held by the device's [`NEMTelemetry`](@ref) and [`NEMObservedState`](@ref).

Offer-side series are named by [`energy_offer_series_name`](@ref), [`energy_max_avail_series_name`](@ref) and
[`fcas_series_name`](@ref); MNSP link series by [`mnsp_series_name`](@ref).
"""
const NEM_SERIES = (
    ramp_up_rate = "ramp_up_rate",
    ramp_down_rate = "ramp_down_rate",
    max_active_power = "max_active_power",
    fixed_load = "fixed_load",
    fixed_load_invoked = "fixed_load_invoked",
    from_to_flow_limit = "from_to_flow_limit",
    to_from_flow_limit = "to_from_flow_limit",
    loss_demand_coefficient = "loss_demand_coefficient",
)


"""
    NEM_TELEMETRY_SERIES

Names of the per-device `SingleTimeSeries` that [`set_unit_conditions!`](@ref) attaches for a unit's
[`NEMTelemetry`](@ref), in AEMO's natural units, as `DISPATCHLOAD` publishes them:

- `agc_status`: `AGCSTATUS`, `0` or `1`, `NaN` at an interval with no row.
- `uigf`: `UIGF`, MW, semi-scheduled units only.
- `ramp_up_limit`, `ramp_down_limit`: `RAMPUPRATE`, `RAMPDOWNRATE`, MW/h.
- `raise_reg_enablement`, `lower_reg_enablement`: the `(min, max)` MW enablement of each service.
- `raise_reg_max_avail`, `lower_reg_max_avail`: the regulation maximum availability, MW.
"""
const NEM_TELEMETRY_SERIES = (
    agc_status = "telemetry_agc_status",
    uigf = "telemetry_uigf",
    ramp_up_limit = "telemetry_ramp_up_limit",
    ramp_down_limit = "telemetry_ramp_down_limit",
    raise_reg_enablement = "telemetry_raise_reg_enablement",
    lower_reg_enablement = "telemetry_lower_reg_enablement",
    raise_reg_max_avail = "telemetry_raise_reg_max_avail",
    lower_reg_max_avail = "telemetry_lower_reg_max_avail",
)


"""
    NEM_OBSERVED_SERIES

Names of the per-device `SingleTimeSeries` that [`set_unit_conditions!`](@ref) attaches for a unit's
[`NEMObservedState`](@ref), in AEMO's natural units: `initial_mw` (`INITIALMW`, MW) and `dispatch_mode`
(`DISPATCHMODE`).
"""
const NEM_OBSERVED_SERIES = (
    initial_mw = "observed_initial_mw",
    dispatch_mode = "observed_dispatch_mode",
)


"""
    energy_offer_series_name(side::OfferSide) -> String

Name of the series holding a device's energy offer curves on `side`.
"""
energy_offer_series_name(side::OfferSide) = "energy_offer" * side_suffix(side)


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
- `prefix`: the series kind, such as `"fcas_trapezium"` or `"fcas_agc_ramp_rate"`.
- `service`: the FCAS [`BidType`](@ref).
- `side`: the offer side; omitted for a series shared by both sides.

# Returns
A `String`.
"""
fcas_series_name(prefix::AbstractString, service::BidType) = "$(prefix)_$(string(service))"
fcas_series_name(prefix::AbstractString, service::BidType, side::OfferSide) = fcas_series_name(prefix, service) * side_suffix(side)
fcas_series_name(prefix::AbstractString, service::BidType, decremental::Bool) = fcas_series_name(prefix, service, offer_side(decremental))


"""
    mnsp_series_name(direction, kind) -> String

Name of an MNSP interchange's `"mnsp_<direction>_<kind>"` series.

# Arguments
- `direction`: the link, `"forward"` or `"reverse"`.
- `kind`: `"offer"` for the band offer curves, `"max_avail"` for the link `MAXAVAIL` in MW.

# Returns
A `String`.
"""
mnsp_series_name(direction::AbstractString, kind::AbstractString) = "mnsp_$(direction)_$(kind)"


"""
    bid_series_name(service::BidType, field::Symbol, direction::BidDirection) -> String

Name of the time series holding one field of a unit's bid: `"bid_<service>_<field>_<direction>"` in
lowercase, e.g. `"bid_energy_offer_curves_gen"`.

# Arguments
- `service`: the bid's [`BidType`](@ref), `ENERGY` or an FCAS market.
- `field`: the field name of [`NEMEnergyBid`](@ref) or [`NEMFCASBid`](@ref), such as `:offer_curves`.
- `direction`: the bid's [`BidDirection`](@ref).

# Returns
A `String`.
"""
function bid_series_name(service::BidType, field::Symbol, direction::BidDirection)
    return lowercase("bid_$(string(service))_$(field)_$(string(direction))")
end
