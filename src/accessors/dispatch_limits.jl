"""
    get_initial_mw(component, initial_time, horizon) -> Union{Nothing, Vector{Float64}}

Full-series read of `component`'s `"initial_mw"` series ([`set_nem_dispatch_limits!`](@ref),
`DISPATCHLOAD.INITIALMW`, net MW for a battery), `horizon` steps from `initial_time`, in
`component`'s `System`'s current display units. `nothing` if `component` carries no such series.

# Returns
`Union{Nothing, Vector{Float64}}`.
"""
function get_initial_mw(component, initial_time, horizon::Integer)
    return _read_dispatch_limit_series(component, "initial_mw", initial_time, horizon)
end


"""
    get_energy_availability(component, initial_time, horizon) -> Union{Nothing, Vector{Float64}}

Full-series read of `component`'s `"availability"` series ([`set_nem_dispatch_limits!`](@ref),
`DISPATCHLOAD.AVAILABILITY`), `horizon` steps from `initial_time`, in `component`'s `System`'s
current display units. `nothing` if `component` carries no such series.

# Returns
`Union{Nothing, Vector{Float64}}`.
"""
function get_energy_availability(component, initial_time, horizon::Integer)
    return _read_dispatch_limit_series(component, "availability", initial_time, horizon)
end


"`component`'s `name` `SingleTimeSeries` over `horizon` steps from `initial_time`, in display units, or `nothing`."
function _read_dispatch_limit_series(component, name::AbstractString, initial_time, horizon::Integer)
    has_time_series(component, SingleTimeSeries, name) || return nothing
    values = get_time_series_values(SingleTimeSeries, component, name; start_time = initial_time, len = horizon)
    return values .* _fcas_units_multiplier(component)
end
