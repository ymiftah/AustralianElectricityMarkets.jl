"""
    _forecast_window_values(container, component, ts_name, start_time) -> Vector

`component`'s `ts_name` forecast values over the container's time steps from `start_time`, read
from the container's default forecast type without scaling factors.

# Arguments
- `container`: the optimization container defining forecast type and horizon.
- `component`: the series owner.
- `ts_name`: the forecast series name.
- `start_time`: the first requested timestamp.

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


"""
    _forecast_window_values(model, component, ts_name, start_time) -> Vector

Read the forecast window through a decision model's time-series cache, or directly from the
container for other operation models. Uses the model's cache setting and ignores scaling factors.
Cached requests must repeat or advance sequentially; clear the model cache before restarting.

# Arguments
- `model`: the operation model owning the container and cache.
- `component`: the series owner.
- `ts_name`: the forecast series name.
- `start_time`: the requested interval timestamp.

# Returns
A vector of forecast values for the model horizon.
"""
function _forecast_window_values(
        model::PSI.OperationModel, component::PSY.Component, ts_name::String, start_time::DateTime,
    )
    return _forecast_window_values(PSI.get_optimization_container(model), component, ts_name, start_time)
end

"""
    _forecast_window_values(model::PSI.DecisionModel, component, ts_name, start_time) -> Vector

Read the current forecast window from the model cache, respecting disabled caching. Structured
NEM bid curves retain at most 24 windows; repeated/sequential timestamps are required when cached.

# Arguments
- `model`: the decision model owning the forecast cache.
- `component`, `ts_name`: the series owner and name.
- `start_time`: the current interval timestamp; clear caches before restarting a sequence.

# Returns
A vector of forecast values without scaling factors.
"""
function _forecast_window_values(
        model::PSI.DecisionModel, component::PSY.Component, ts_name::String, start_time::DateTime,
    )
    container = PSI.get_optimization_container(model)
    return PSI.get_time_series_values!(
        PSI.get_default_time_series_type(container), model, component, ts_name, start_time,
        length(PSI.get_time_steps(container));
        interval = PSI.get_interval(PSI.get_settings(model)), ignore_scaling_factors = true,
    )
end
