"""
    _max_active_power(availability, initial_mw, ramp_down_rate, Δ) -> Float64

The upper dispatch limit of one unit in one interval: its `availability`, raised to the ramp-down
floor `initial_mw - ramp_down_rate × Δ` when that floor is higher.

# Arguments
- `availability`: the dispatch envelope upper bound, in MW or per unit of the base.
- `initial_mw`: the unit's metered output at the start of the interval, in the same unit.
- `ramp_down_rate`: the ramp-down rate per hour, in the same unit.
- `Δ`: the interval length in hours.

# Returns
A `Float64` in the same unit as `availability`.
"""
function _max_active_power(availability::Real, initial_mw::Real, ramp_down_rate::Real, Δ::Real)
    return max(availability, initial_mw - ramp_down_rate * Δ)
end


"""
    _agc_ramp_rate(ramp_rate, availability, interval_hours) -> Float64

The AGC ramp rate of one regulation side of one interval: the larger of the dispatch ramp rate and the
regulation availability spread over `interval_hours`. A `NaN` availability leaves the ramp rate as it is;
a `NaN` ramp rate stays `NaN`.

# Arguments
- `ramp_rate`: the dispatch ramp rate per hour, per unit of the base.
- `availability`: the regulation availability, per unit of the base, or `NaN` when absent.
- `interval_hours`: the length of one dispatch interval in hours.

# Returns
A `Float64` per unit of the base per hour.
"""
function _agc_ramp_rate(ramp_rate::Real, availability::Real, interval_hours::Real)
    isnan(ramp_rate) && return NaN
    isnan(availability) && return Float64(ramp_rate)
    return max(ramp_rate, availability / interval_hours)
end
