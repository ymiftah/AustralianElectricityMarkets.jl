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
