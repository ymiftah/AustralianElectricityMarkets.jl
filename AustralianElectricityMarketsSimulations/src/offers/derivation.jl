"""
    energy_availability_series_name(side::OfferSide) -> String

Name of the series holding a device's derived energy availability on `side`, system-base per unit.

# Arguments
- `side`: the [`OfferSide`](@ref).

# Returns
A `String`.
"""
energy_availability_series_name(side::OfferSide) = "energy_availability" * side_suffix(side)


"""
    energy_availability_series_name(device, side::OfferSide) -> String

Name of the series holding `device`'s derived energy availability, as the dispatch formulation reads
it: per side for a `PowerSystems.Storage` device, and the generation-side name for any other device,
whose single energy bid may be on either side.

# Arguments
- `device`: the NEM dispatch device.
- `side`: the [`OfferSide`](@ref) of the energy bid.

# Returns
A `String`.
"""
function energy_availability_series_name(device, side::OfferSide)
    return energy_availability_series_name(device isa PSY.Storage ? side : OfferSide.GEN)
end


"""
    referred_offer_curves(curves, factor::Real) -> Vector{PiecewiseStepData}

`curves` with their band prices referred to the reference node by `factor`, AEMO's unit loss factor,
and rounded to cents.

# Arguments
- `curves`: the price-band curves of an energy offer, in natural units.
- `factor`: the loss factor to divide each price by.

# Returns
A `Vector{PowerSystems.PiecewiseStepData}`.
"""
function referred_offer_curves(curves, factor::Real)
    return [
        PSY.PiecewiseStepData(PSY.get_x_coords(c), round.(PSY.get_y_coords(c) ./ factor; digits = 2)) for c in curves
    ]
end


"""
    effective_energy_availability(max_avail, uigf, ramp_up_raw, pinned::Bool) -> Vector{Float64}

The energy availability of a unit per interval, in the unit of `max_avail`: its energy `MAXAVAIL`,
limited by `uigf` where one is published, and zero for a non-scheduled load or an interval with no
`DISPATCHLOAD` row (a `NaN` ramp limit).

# Arguments
- `max_avail`: the energy bid `MAXAVAIL` per interval.
- `uigf`: the unit initial generation forecast per interval, or `nothing` when the unit is not
  semi-scheduled.
- `ramp_up_raw`: the telemetered ramp-up limit per interval, `NaN` at an interval with no row.
- `pinned`: whether the unit is a non-scheduled load, dispatched by constraint rather than by offer.

# Returns
A `Vector{Float64}`.
"""
function effective_energy_availability(max_avail::AbstractVector, uigf, ramp_up_raw::AbstractVector, pinned::Bool)
    return [
        (pinned || isnan(ramp_up_raw[i])) ? 0.0 : (isnothing(uigf) ? max_avail[i] : min(max_avail[i], uigf[i]))
            for i in eachindex(max_avail)
    ]
end


"""
    effective_ramp_limit(bid_mw_per_min, telemetry_mw_per_h) -> Float64

A unit's effective ramp limit for one direction in one interval: the lesser of its bid ramp rate and
its telemetered ramp rate, as AEMO publishes `DISPATCHLOAD.RAMPUPRATE` and `RAMPDOWNRATE`. A `NaN`
bid rate means the bid sets no limit, so the telemetered rate stands; a `NaN` telemetered rate means
the interval has no `DISPATCHLOAD` row and stays `NaN`.

# Arguments
- `bid_mw_per_min`: the bid `ROCUP` or `ROCDOWN`, MW/min, `NaN` when the bid has none.
- `telemetry_mw_per_h`: the telemetered ramp limit, MW/h, `NaN` at an interval with no row.

# Returns
A `Float64` in MW/h.
"""
function effective_ramp_limit(bid_mw_per_min::Real, telemetry_mw_per_h::Real)
    isnan(telemetry_mw_per_h) && return NaN
    isnan(bid_mw_per_min) && return Float64(telemetry_mw_per_h)
    return min(bid_mw_per_min * 60, Float64(telemetry_mw_per_h))
end


"""
    effective_ramp_limits(bid_up, bid_down, telemetry_up, telemetry_down) -> (Vector{Float64}, Vector{Float64})

[`effective_ramp_limit`](@ref) of both directions, elementwise, in MW/h.

# Arguments
- `bid_up`, `bid_down`: the bid ramp rates, MW/min.
- `telemetry_up`, `telemetry_down`: the telemetered ramp limits, MW/h.

# Returns
A tuple `(up, down)` of `Vector{Float64}`.
"""
function effective_ramp_limits(bid_up::AbstractVector, bid_down::AbstractVector, telemetry_up::AbstractVector, telemetry_down::AbstractVector)
    return (
        [effective_ramp_limit(bid_up[i], telemetry_up[i]) for i in eachindex(telemetry_up)],
        [effective_ramp_limit(bid_down[i], telemetry_down[i]) for i in eachindex(telemetry_down)],
    )
end


"""
    effective_regulation_enablement(enablement_min, enablement_max, telemetry_min, telemetry_max)

A regulation FCAS trapezium's enablement after AEMO *FCAS Model in NEMDE* §4.1: the more restrictive
of the bid enablement and the AGC enablement limits. A missing telemetry limit applies no
restriction, so the bid's own breakpoint stands. A `0.0` telemetry limit is a real limit here,
unlike [`scale_fcas_trapezium`](@ref), which treats it as absent.

# Arguments
- `enablement_min`, `enablement_max`: the bid trapezium's enablement breakpoints, MW.
- `telemetry_min`, `telemetry_max`: the telemetered enablement limits, MW, or `nothing`.

# Returns
A tuple `(enablement_min, enablement_max)` in MW.
"""
function effective_regulation_enablement(
        enablement_min::Real, enablement_max::Real, telemetry_min, telemetry_max,
    )
    lo = isnothing(telemetry_min) ? Float64(enablement_min) : max(Float64(enablement_min), Float64(telemetry_min))
    hi = isnothing(telemetry_max) ? Float64(enablement_max) : min(Float64(enablement_max), Float64(telemetry_max))
    return (lo, hi)
end


"""
    effective_regulation_max_avail(bid_max_avail, telemetry_max_avail) -> Float64

A regulation service's effective maximum availability: the lesser of the bid `MAXAVAIL` and the
telemetered value, `DISPATCHLOAD.RAISEREGAVAILABILITY` or `LOWERREGAVAILABILITY`, which AEMO already
publishes as the minimum of the two. A `nothing` or `NaN` bid availability leaves the telemetered
value; a `NaN` telemetered value means the interval has no row and stays `NaN`.

# Arguments
- `bid_max_avail`: the regulation FCAS bid `MAXAVAIL`, MW, or `nothing`.
- `telemetry_max_avail`: the telemetered regulation availability, MW.

# Returns
A `Float64` in MW.
"""
function effective_regulation_max_avail(bid_max_avail, telemetry_max_avail::Real)
    isnan(telemetry_max_avail) && return NaN
    (isnothing(bid_max_avail) || isnan(bid_max_avail)) && return Float64(telemetry_max_avail)
    return min(Float64(bid_max_avail), Float64(telemetry_max_avail))
end


"""
    fcas_trapezium_values(points, max_avail::Real, base::Real) -> NTuple{7, Float64}

One interval of an FCAS trapezium series, per unit of the system base: the bid's four MW breakpoints
and `max_avail`, then the ramp rates, which AEMO's FCAS offers do not publish (`NaN`). Returned as a
tuple, the value type the FCAS series store and the accessors rebuild a `FCASTrapezium` from.

# Arguments
- `points`: the bid's `ENABLEMENTMIN`, `LOWBREAKPOINT`, `HIGHBREAKPOINT` and `ENABLEMENTMAX`, MW.
- `max_avail`: the bid `MAXAVAIL`, MW.
- `base`: the system base power, MW.

# Returns
A `NTuple{7, Float64}`.
"""
fcas_trapezium_values(points, max_avail::Real, base::Real) = (Float64.(points)..., Float64(max_avail), NaN, NaN) ./ base


"""
    tie_break_scale(width::Real, reference_width::Real) -> Float64

The tie-break scale of a price-tied energy band: its `width` over the widest band of its tie group,
`reference_width`, and zero when the group has no width.

# Arguments
- `width`: the band's MW width at the interval.
- `reference_width`: the widest band width in the tie group at the interval.

# Returns
A `Float64`.
"""
tie_break_scale(width::Real, reference_width::Real) = reference_width > 0.0 ? width / reference_width : 0.0
