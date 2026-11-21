"""
    effective_ramp_limit(bid_mw_per_min::Float64, telemetry_mw_per_h::Float64) -> Float64

A unit's effective ramp limit for one direction in one interval: the lesser of its bid ramp rate and
its telemetered ramp rate, as AEMO publishes `DISPATCHLOAD.RAMPUPRATE` and `RAMPDOWNRATE`. A `NaN`
bid rate leaves the telemetered rate, and a `NaN` telemetered rate stays `NaN`.

# Arguments
- `bid_mw_per_min`: the bid `ROCUP` or `ROCDOWN`, MW/min, `NaN` when the bid has none.
- `telemetry_mw_per_h`: the telemetered ramp limit, MW/h, `NaN` at an interval with no row.

# Returns
A `Float64` in MW/h.
"""
function effective_ramp_limit(bid_mw_per_min::Float64, telemetry_mw_per_h::Float64)::Float64
    isnan(telemetry_mw_per_h) && return NaN
    isnan(bid_mw_per_min) && return telemetry_mw_per_h
    return min(bid_mw_per_min * 60, telemetry_mw_per_h)
end


"""
    effective_regulation_max_avail(bid_max_avail::Float64, telemetry_max_avail::Float64) -> Float64

A regulation service's effective maximum availability: the lesser of the bid `MAXAVAIL` and the
telemetered value, `DISPATCHLOAD.RAISEREGAVAILABILITY` or `LOWERREGAVAILABILITY`, which AEMO already
publishes as the minimum of the two. A `NaN` bid availability leaves the telemetered value, and a
`NaN` telemetered value means the interval has no row and stays `NaN`.

# Arguments
- `bid_max_avail`: the regulation FCAS bid `MAXAVAIL`, MW, `NaN` when the bid has none.
- `telemetry_max_avail`: the telemetered regulation availability, MW, `NaN` at an interval with no row.

# Returns
A `Float64` in MW.
"""
function effective_regulation_max_avail(bid_max_avail::Float64, telemetry_max_avail::Float64)::Float64
    isnan(telemetry_max_avail) && return NaN
    isnan(bid_max_avail) && return telemetry_max_avail
    return min(bid_max_avail, telemetry_max_avail)
end


"""
    agc_ramp_rate(ramp_rate::Float64, availability::Float64, interval_hours::Float64) -> Float64

The AGC ramp rate of one regulation side of one interval: the larger of the dispatch ramp rate and the
regulation availability spread over `interval_hours`. A `NaN` availability leaves the ramp rate as it is,
and a `NaN` ramp rate stays `NaN`.

# Arguments
- `ramp_rate`: the dispatch ramp rate per hour, per unit of the base.
- `availability`: the regulation availability, per unit of the base, or `NaN` when absent.
- `interval_hours`: the length of one dispatch interval in hours.

# Returns
A `Float64` per unit of the base per hour.
"""
function agc_ramp_rate(ramp_rate::Float64, availability::Float64, interval_hours::Float64)::Float64
    isnan(ramp_rate) && return NaN
    isnan(availability) && return ramp_rate
    return max(ramp_rate, availability / interval_hours)
end
