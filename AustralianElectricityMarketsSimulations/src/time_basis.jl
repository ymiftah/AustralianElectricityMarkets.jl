"Length of one NEM dispatch interval, in hours."
const DISPATCH_INTERVAL_HOURS = 1 / 12

"Length of one NEM dispatch interval."
const DISPATCH_INTERVAL = Dates.Minute(5)

"""
    interval_hours(resolution::Dates.Period) -> Float64

The length of `resolution` in hours.

# Example
```julia
interval_hours(Minute(30))  # 0.5
```
"""
function interval_hours(resolution::Dates.Period)
    return Dates.value(Dates.Millisecond(resolution)) / 3_600_000
end

"""
    interval_cost_coefficient(price::Real, resolution::Dates.Period = DISPATCH_INTERVAL)

Converts a `\$/MWh` price into an objective coefficient for one interval of length `resolution`.

# Arguments
- `price`: a price in `\$/MWh`.
- `resolution`: the interval length; defaults to one NEM dispatch interval (5 minutes).

# Returns
The coefficient in `\$/MW` for a dispatch variable over one interval, as a `Float64`.

# Example
```julia
interval_cost_coefficient(300.0)              # 25.0
interval_cost_coefficient(300.0, Minute(30))  # 150.0
```
"""
function interval_cost_coefficient(price::Real, resolution::Dates.Period = DISPATCH_INTERVAL)
    return price * interval_hours(resolution)
end
