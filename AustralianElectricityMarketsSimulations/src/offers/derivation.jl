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
