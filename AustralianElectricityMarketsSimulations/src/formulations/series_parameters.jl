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
