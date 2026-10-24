"""
    prepare_replication!(sys::PSY.System) -> PSY.System

Prepares a populated system for dispatch simulation using only its attached time series:
effective FCAS offers, tie-break scales and one-interval five-minute forecast windows.

# Arguments
- `sys`: a system with at least two timestamps of single time series and no forecasts.

# Returns
The modified system. Throws `ArgumentError` when forecasts already exist or input series are absent.
"""
function prepare_replication!(sys::PSY.System)
    counts = PSY.get_time_series_counts(sys)
    counts.forecast_count == 0 || throw(ArgumentError("prepare_replication!: the system already has forecast time series."))
    counts.static_time_series_count > 0 || throw(ArgumentError("prepare_replication!: attach input time series before preparation."))
    _, n = PSY.check_time_series_consistency(sys, PSY.SingleTimeSeries)
    n >= 2 || throw(ArgumentError("prepare_replication!: at least two input timestamps are required for forecast windows."))
    set_fcas_effective_offers!(sys)
    set_tie_break_scales!(sys)
    PSY.transform_single_time_series!(sys, DISPATCH_INTERVAL, DISPATCH_INTERVAL)
    return sys
end
