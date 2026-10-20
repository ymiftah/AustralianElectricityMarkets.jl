function table_requirements(::NetworkConfiguration)
    error("Not implemented")
end


function nem_system(db, network_configuration::T) where {T <: NetworkConfiguration}
    error("Not implemented for $(typeof(network_configuration))")
end


"""
    _single_series(name, start_date, values, resolution) -> SingleTimeSeries

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
function _single_series(name::AbstractString, start_date, values, resolution)
    timestamps = [start_date + (k - 1) * resolution for k in 1:length(values)]
    return SingleTimeSeries(; name = name, data = TimeArray(timestamps, values), resolution = resolution)
end
