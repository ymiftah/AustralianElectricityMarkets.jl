"""
    _max_avail_series_name(side::OfferSide) -> String

Name of the energy bid `MAXAVAIL` series on `side`, the series the dispatch parameters register for
their availability (MW).

# Arguments
- `side`: the [`OfferSide`](@ref) of the energy bid.

# Returns
A `String`.
"""
function _max_avail_series_name(side::OfferSide)
    direction = side == OfferSide.LOAD ? AustralianElectricityMarkets.BidDirection.LOAD : AustralianElectricityMarkets.BidDirection.GEN
    return AustralianElectricityMarkets.bid_series_name(BidType.ENERGY, :max_avail, direction)
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
