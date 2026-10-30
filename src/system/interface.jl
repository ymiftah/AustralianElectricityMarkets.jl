function table_requirements(::NetworkConfiguration)
    error("Not implemented")
end


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

# Returns
A `SingleTimeSeries`.
"""
function single_series(name::AbstractString, start_date, values, resolution)
    timestamps = [start_date + (k - 1) * resolution for k in 1:length(values)]
    return SingleTimeSeries(; name = name, data = TimeArray(timestamps, values), resolution = resolution)
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
    _registration_spans(units) -> Dict{String, Tuple{DateTime, DateTime}}

Maps each `DUID` of `units` to its registration span `(REGISTERED_FROM, REGISTERED_UNTIL)`, as
[`read_units`](@ref) reports it.
"""
function _registration_spans(units)
    return Dict(String(r.DUID) => (r.REGISTERED_FROM, r.REGISTERED_UNTIL) for r in eachrow(units))
end


"""
    _is_registered(registered, duid, t) -> Bool

Whether `duid` is registered at the interval-ending stamp `t`, that is `REGISTERED_FROM < t <=
REGISTERED_UNTIL`. A `nothing` `registered` means every unit is registered at every stamp; a `duid`
absent from a span dictionary is not registered.
"""
function _is_registered(::Nothing, duid, t)
    return true
end
function _is_registered(registered::AbstractDict, duid, t)
    span = get(registered, String(duid), nothing)
    isnothing(span) && return false
    from, until = span
    return from < t <= until
end
