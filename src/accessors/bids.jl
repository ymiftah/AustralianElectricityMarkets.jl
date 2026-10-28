"""
    get_storage_energy_max_avail(component, initial_time, horizon) -> Union{Nothing, NamedTuple}

`component`'s energy bid `MAXAVAIL` for each direction, as attached by
[`set_market_bids!`](@ref), `horizon` steps from `initial_time`, in `component`'s `System`'s
current display units.

# Returns
`(gen = Vector{Float64}, load = Vector{Float64})`, or `nothing` unless both directions'
series are attached.
"""
function get_storage_energy_max_avail(component, initial_time, horizon::Integer)
    gen, load = (_read_dispatch_limit_series(component, energy_max_avail_series_name(side), initial_time, horizon) for side in (OfferSide.GEN, OfferSide.LOAD))
    (isnothing(gen) || isnothing(load)) && return nothing
    return (; gen, load)
end
