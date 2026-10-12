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
    has_time_series(component, Deterministic, "energy_max_avail") || return nothing
    has_time_series(component, Deterministic, "energy_max_avail_decremental") || return nothing
    multiplier = _fcas_units_multiplier(component)
    read(name) = get_time_series_values(Deterministic, component, name; start_time = initial_time, len = horizon) .* multiplier
    return (gen = read("energy_max_avail"), load = read("energy_max_avail_decremental"))
end
