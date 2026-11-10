# Adds a NEM service whose type has no PowerSystems validation entry, without the per-component
# "does not exist in validation configuration" warning; runchecks is restored afterwards.
function _add_nem_service!(sys::PSY.System, service::PSY.Service, devices)
    runchecks = PSY.get_runchecks(sys)
    PSY.set_runchecks!(sys, false)
    try
        PSY.add_service!(sys, service, devices)
    finally
        PSY.set_runchecks!(sys, runchecks)
    end
    return
end


function table_requirements(::NetworkConfiguration)
    error("Not implemented")
end


"""
    nem_system(db, network_configuration; kwargs...)

Builds a regional NEM system from cached market data according to `network_configuration`.

# Arguments
- `db`: the market cache connection.
- `network_configuration`: a [`RegionalNetworkConfiguration`](@ref) or
  [`NEMDEConfiguration`](@ref).
- `as_of`: the `Date` or `DateTime` for resolving static metadata; regional construction defaults
  to the latest cached version and NEMDE construction to the first requested interval.
- `date_range`: required for NEMDE construction, including the exclusive stop.
- `kwargs`: configuration-specific inputs and `PowerSystems.System` storage options.

# Returns
A `PowerSystems.System` populated according to the requested configuration.

# Example
```julia
sys = nem_system(db, RegionalNetworkConfiguration())
```
"""
function nem_system(db, network_configuration::T) where {T <: NetworkConfiguration}
    error("Not implemented for $(typeof(network_configuration))")
end


"""
    single_series(name, start_date, values, resolution) -> SingleTimeSeries

Builds a `SingleTimeSeries` named `name` holding `values`, one per interval of `resolution`
starting at `start_date`.

# Arguments
- `name`: The series name.
- `start_date`: The timestamp of the first value.
- `values`: The per-interval values, one element per interval.
- `resolution`: The spacing between consecutive timestamps.
- `kwargs`: Passed to `SingleTimeSeries`, e.g. `scaling_factor_multiplier`.

# Returns
A `SingleTimeSeries`.
"""
function single_series(name::AbstractString, start_date, values, resolution; kwargs...)
    timestamps = [start_date + (k - 1) * resolution for k in 1:length(values)]
    return SingleTimeSeries(; name = name, data = TimeArray(timestamps, values), resolution = resolution, kwargs...)
end


"""
    single_series(name, timestamps, values; kwargs...) -> SingleTimeSeries

Builds a `SingleTimeSeries` named `name` holding `values` on `timestamps`, its resolution inferred
from their spacing.

# Arguments
- `name`: The series name.
- `timestamps`: One timestamp per value.
- `values`: The values.
- `kwargs`: Passed to `SingleTimeSeries`, e.g. `scaling_factor_multiplier`.

# Returns
A `SingleTimeSeries`.
"""
function single_series(name::AbstractString, timestamps::AbstractVector, values; kwargs...)
    return SingleTimeSeries(; name = name, data = TimeArray(timestamps, values), kwargs...)
end


"""
    remove_single_series!(sys, component, name)

Removes `component`'s `SingleTimeSeries` named `name` from `sys`, if it has one.

# Arguments
- `sys`: The `System` holding `component`.
- `component`: The component.
- `name`: The series name.

# Returns
`nothing`.
"""
function remove_single_series!(sys, component, name::AbstractString)
    has_time_series(component, SingleTimeSeries, name) && remove_time_series!(sys, SingleTimeSeries, component, name)
    return
end


"""
    replace_single_series!(sys, component, ts::SingleTimeSeries)

Attaches `ts` to `component`, first removing an existing `SingleTimeSeries` of the same name.

# Arguments
- `sys`: The `System` holding `component`.
- `component`: The component.
- `ts`: The series to attach.

# Returns
`nothing`.
"""
function replace_single_series!(sys, component, ts::SingleTimeSeries)
    remove_single_series!(sys, component, get_name(ts))
    add_time_series!(sys, component, ts)
    return
end


"""
    _is_registered(registration::NEMRegistration, t) -> Bool

Whether the unit is registered at the interval-ending stamp `t`, that is `registered_from < t <=
registered_until`.
"""
function _is_registered(registration::NEMRegistration, t)
    return registration.registered_from < t <= registration.registered_until
end
