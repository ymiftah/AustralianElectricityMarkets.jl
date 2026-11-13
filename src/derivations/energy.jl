"""
    referred_price(price::Float64, loss_factor::Float64) -> Float64

`price` referred to the reference node by `loss_factor`, AEMO's unit loss factor, and rounded to cents.

# Arguments
- `price`: the energy offer band price, in \$/MWh.
- `loss_factor`: the loss factor to divide the price by.

# Returns
A `Float64`.
"""
function referred_price(price::Float64, loss_factor::Float64)::Float64
    return round(price / loss_factor; digits = 2)
end
