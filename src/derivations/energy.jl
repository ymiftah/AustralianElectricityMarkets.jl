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
