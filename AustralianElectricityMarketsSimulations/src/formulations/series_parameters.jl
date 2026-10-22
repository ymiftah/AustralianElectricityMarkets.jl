"""
    _add_series_parameter!(container, param, D, components, ts_name, meta; axes = ()) -> PSI.ParameterContainer

Adds `param` keyed `(D, meta)` with one row per component of `components`, each valued from that
component's `ts_name` forecast over the container's time steps through
`PowerSimulations._unwrap_for_param` on the extra `axes`, with multipliers `1.0`. The rows are
registered by forecast UUID, so PowerSimulations' time-series parameter update refreshes them.

# Arguments
- `container`: the optimization container of the model being built.
- `param`: the `PSI.ParameterType` instance to add.
- `D`: the component type the parameter is keyed by.
- `components`: the components carrying a `ts_name` forecast, one row each.
- `ts_name`: the forecast name.
- `meta`: the container meta.
- `axes`: the axes between the component and time axes, `()` for a scalar parameter.

# Returns
The new parameter container.
"""
function _add_series_parameter!(
        container::PSI.OptimizationContainer, param::PSI.ParameterType, ::Type{D}, components,
        ts_name::String, meta::String; axes::Tuple = (),
    ) where {D <: PSY.Component}
    ts_type = PSI.get_default_time_series_type(container)
    settings = PSI.get_settings(container)
    interval, resolution = PSI.get_interval(settings), PSI.get_resolution(settings)
    names = PSY.get_name.(components)
    uuids = [
        string(
            IS.get_time_series_uuid(
                ts_type, c, ts_name; resolution = PSI._to_is_resolution(resolution), interval = PSI._to_is_interval(interval),
            ),
        ) for c in components
    ]
    time_steps = PSI.get_time_steps(container)
    param_container = PSI.add_param_container!(
        container, param, D, ts_type, ts_name, uuids, names, axes, time_steps; meta = meta,
    )
    attributes = PSI.get_attributes(param_container)
    jm = PSI.get_jump_model(container)
    values = PSI.get_parameter_array_data(param_container)
    multipliers = PSI.get_multiplier_array_data(param_container)
    for (i, c) in enumerate(components)
        raw = PSI.get_time_series_initial_values!(container, ts_type, c, ts_name; interval = interval, resolution = resolution)
        for t in time_steps
            PSI._set_parameter_at!(values, jm, PSI._unwrap_for_param(param, raw[t], axes), i, t)
        end
        PSI._set_multiplier_at!(multipliers, 1.0, i)
        PSI.add_component_name!(attributes, names[i], uuids[i])
    end
    return param_container
end


"""
    _forecast_window_values(container, component, ts_name, start_time) -> Vector

`component`'s `ts_name` forecast values over the container's time steps from `start_time`, read
from the container's default forecast type without scaling factors.

# Returns
A `Vector` of the forecast's element type.
"""
function _forecast_window_values(
        container::PSI.OptimizationContainer, component::PSY.Component, ts_name::String, start_time::DateTime,
    )
    ts_type = PSI.get_default_time_series_type(container)
    forecast = IS.get_time_series(ts_type, component, ts_name; start_time = start_time, count = 1)
    return IS.get_time_series_values(
        component, forecast; start_time = start_time, len = length(PSI.get_time_steps(container)),
        ignore_scaling_factors = true,
    )
end
