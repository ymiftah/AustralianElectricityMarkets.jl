function _check_energy_limit_series(sys, model, initial_time, n_intervals)
    for d in PSI.get_available_components(model, sys)
        name = PSY.get_name(d)
        series = if d isa PSY.Storage
            ("energy_max_avail", "energy_max_avail_decremental")
        else
            semi = get(PSY.get_ext(d), "nem_semi_scheduled", nothing)
            semi isa Bool || throw(ArgumentError("$name: missing schedule classification; call set_nem_energy_limits!"))
            semi ? ("energy_max_avail", "energy_uigf") : ("energy_max_avail",)
        end
        for key in series
            remedy = d isa PSY.Storage ? "set_market_bids! for both directions" : "set_nem_energy_limits!"
            PSY.has_time_series(d, PSY.SingleTimeSeries, key) || throw(ArgumentError("$name: missing $key; call $remedy"))
            values = PSY.get_time_series_values(PSY.SingleTimeSeries, d, key; start_time = initial_time, len = n_intervals, ignore_scaling_factors = true)
            bad = findfirst(v -> !isfinite(v) || v < 0, values)
            isnothing(bad) || throw(ArgumentError("$name at interval $bad: invalid $key"))
        end
    end
    return
end

"""
    check_dispatch_envelope(sys, template, initial_time, n_intervals) -> Nothing

Validates complete, finite, non-negative separate energy availability and UIGF inputs for
NEM dispatch devices, including both storage offer directions over the requested intervals. Conflicts with ramping are
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
