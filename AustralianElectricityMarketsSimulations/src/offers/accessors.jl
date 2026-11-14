"""
    get_initial_mw(component, initial_time, horizon) -> Vector{Float64}

Window of `component`'s observed `initial_mw` ([`set_unit_conditions!`](@ref), `DISPATCHLOAD.INITIALMW`,
net MW for a battery), `horizon` steps from `initial_time`, in `component`'s `System`'s current display units.

# Returns
`Vector{Float64}`.
"""
function get_initial_mw(component, initial_time, horizon::Integer)
    return _unit_window(component, AustralianElectricityMarkets.get_observed_state(component).initial_mw, initial_time, horizon)
end


# `key`'s raw values on `component` over `horizon` steps from `initial_time`; a static `key` is repeated.
function _raw_window(component, key, initial_time, horizon::Integer)
    key isa IS.StaticTimeSeriesKey || return fill(Float64(key), horizon)
    return Float64.(IS.get_time_series_values(component, key; start_time = initial_time, len = horizon))::Vector{Float64}
end


# `key`'s values on `component` per unit of the system base, over `horizon` steps from `initial_time`.
function _unit_values(component, key, initial_time, horizon::Integer)
    return _raw_window(component, key, initial_time, horizon) ./ PSY.get_system_base_power(component)
end


# `key`'s values on `component` per unit of the system base and in display units, or `nothing` for an absent key.
function _unit_window(component, key, initial_time, horizon::Integer)
    isnothing(key) && return nothing
    return _unit_values(component, key, initial_time, horizon) .* _fcas_units_multiplier(component)
end
