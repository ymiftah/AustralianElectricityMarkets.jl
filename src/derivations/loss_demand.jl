"""
    loss_demand_coefficient(model::InterconnectorLossModel, demand::AbstractDict)::Float64

The demand term of an interchange's loss factor, `Σ_r demand_coefficients[r] × demand[r]`, in the
units of `demand`, where `demand[r]` is the summed demand of region `r` and a region the model does
not name contributes zero.

# Arguments
- `model`: the interchange's [`InterconnectorLossModel`](@ref).
- `demand`: the summed demand per region name, in the caller's units.

# Returns
A `Float64`, in the units of `demand`.
"""
function loss_demand_coefficient(model::InterconnectorLossModel, demand::AbstractDict)::Float64
    return sum((c * get(demand, r, 0.0) for (r, c) in model.demand_coefficients); init = 0.0)
end
