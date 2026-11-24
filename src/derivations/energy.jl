# The NEM market price floor, in $/MWh at the regional reference node.
const MARKET_PRICE_FLOOR = -1000.0

"""
    referred_price(price::Float64, loss_factor::Float64) -> Float64

`price` referred to the reference node by `loss_factor`, AEMO's unit loss factor, rounded to cents and no lower than the market price floor.

# Arguments
- `price`: the energy offer band price, in `\$/MWh`.
- `loss_factor`: the loss factor to divide the price by.

# Returns
A `Float64`.
"""
function referred_price(price::Float64, loss_factor::Float64)::Float64
    return max(round(price / loss_factor; digits = 2), MARKET_PRICE_FLOOR)
end


"""
    effective_energy_availability(max_avail, uigf, ramp_up_raw, pinned::Bool) -> Float64

The energy availability of a unit in one interval, in the unit of `max_avail`: its energy `MAXAVAIL`,
limited by `uigf` for a semi-scheduled unit, and zero for a non-scheduled load or an interval with no
`DISPATCHLOAD` row (a `NaN` ramp limit). Broadcast it over the intervals of a series.

# Arguments
- `max_avail`: the energy bid `MAXAVAIL`.
- `uigf`: the unconstrained intermittent generation forecast, or `nothing` when the unit is not
  semi-scheduled; a `NaN` forecast gives a `NaN` availability.
- `ramp_up_raw`: the telemetered ramp-up limit, `NaN` at an interval with no row.
- `pinned`: whether the unit is a non-scheduled load, dispatched by constraint rather than by offer.

# Returns
A `Float64`.

# Example
```julia
effective_energy_availability.([10.0, 10.0], [8.0, 12.0], [60.0, 60.0], false)  # [8.0, 10.0]
```
"""
function effective_energy_availability(max_avail::Real, uigf::Union{Nothing, Real}, ramp_up_raw::Real, pinned::Bool)::Float64
    (pinned || isnan(ramp_up_raw)) && return 0.0
    return isnothing(uigf) ? Float64(max_avail) : Float64(min(max_avail, uigf))
end
