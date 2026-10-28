"""
    check_dispatch_envelope(sys, template, initial_time, n_intervals) -> Nothing

Validates complete, finite, non-negative separate energy availability and UIGF inputs for
NEM dispatch devices over the requested intervals. Conflicts with ramping are
resolved by the model's priced violation variables.

# Arguments
- `sys`: the system whose time series are checked.
- `template`: the dispatch template.
- `initial_time`: the first interval timestamp.
- `n_intervals`: the number of intervals to check.

# Returns
`nothing`; invalid or missing energy inputs raise `ArgumentError`.
"""
function check_dispatch_envelope(sys::PSY.System, template::PSI.ProblemTemplate, initial_time::DateTime, n_intervals::Integer)
    for model in values(PSI.get_device_models(template))
        PSI.get_formulation(model) <: AbstractNEMDispatch || continue
        _check_energy_limit_series(sys, model, initial_time, n_intervals)
    end
    return
end


# Throws unless every available device of `model` carries finite, non-negative energy-limit series.
function _check_energy_limit_series(sys, model::PSI.DeviceModel, initial_time, n_intervals)
    for d in PSI.get_available_components(model, sys)
        name = PSY.get_name(d)
        keys, remedy = _energy_limit_series(d)
        for key in keys
            PSY.has_time_series(d, PSY.SingleTimeSeries, key) || throw(ArgumentError("$name: missing $key; $remedy"))
            values = PSY.get_time_series_values(PSY.SingleTimeSeries, d, key; start_time = initial_time, len = n_intervals, ignore_scaling_factors = true)
            bad = findfirst(v -> !isfinite(v) || v < 0, values)
            isnothing(bad) || throw(ArgumentError("$name at interval $bad: invalid $key"))
        end
    end
    return
end


# The energy-limit series names a device's dispatch reads, and the setter that attaches them.
function _energy_limit_series(d::PSY.Storage)
    return energy_max_avail_series_name.((OfferSide.GEN, OfferSide.LOAD)), "call set_market_bids! for both directions"
end

function _energy_limit_series(d)
    semi = is_semi_scheduled(d)
    max_avail = energy_max_avail_series_name(OfferSide.GEN)
    return (semi ? (max_avail, NEM_SERIES.uigf) : (max_avail,)), "call set_nem_energy_limits!"
end
