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


"""
    _forecast_window_values(model, component, ts_name, start_time) -> Vector

Read the forecast window through a decision model's time-series cache, or directly from the
container for other operation models. Uses the model's cache setting and ignores scaling factors.

# Returns
A vector of forecast values for the model horizon.
"""
function _forecast_window_values(
        model::PSI.OperationModel, component::PSY.Component, ts_name::String, start_time::DateTime,
    )
    return _forecast_window_values(PSI.get_optimization_container(model), component, ts_name, start_time)
end

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
