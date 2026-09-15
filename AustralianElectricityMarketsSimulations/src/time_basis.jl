"Length of one NEM dispatch interval, in hours."
const DISPATCH_INTERVAL_HOURS = 1 / 12

"""
    interval_cost_coefficient(price::Real)

Converts a `\$/MWh` price into an objective coefficient for one NEM dispatch interval.

# Arguments
- `price`: a price in `\$/MWh`.

# Returns
The coefficient in `\$/MW` for a dispatch variable over one dispatch interval, as a `Float64`.

# Example
```julia
interval_cost_coefficient(300.0)  # 25.0
```
"""
function interval_cost_coefficient(price::Real)
    return price * DISPATCH_INTERVAL_HOURS
end
