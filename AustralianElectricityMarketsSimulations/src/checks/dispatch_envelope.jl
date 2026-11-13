"""
    check_dispatch_envelope(template, sys) -> Nothing

Validates complete, finite, non-negative separate energy availability and UIGF inputs for
NEM dispatch devices over the replay intervals of `sys` (`replay_intervals(sys)`). Conflicts with
ramping are resolved by the model's priced violation variables.

# Arguments
- `template`: the dispatch template.
- `sys`: the system built by [`nem_system`](@ref), whose time series are checked.

# Returns
`nothing`; invalid or missing energy inputs, or a system without replay intervals, raise `ArgumentError`.
"""
function check_dispatch_envelope(template::PSI.ProblemTemplate, sys::PSY.System)
    intervals = replay_intervals(sys)
    isempty(intervals) && throw(ArgumentError("check_dispatch_envelope: the system has a single forecast window and no replay intervals"))
    for model in values(PSI.get_device_models(template))
        PSI.get_formulation(model) <: AbstractNEMDispatch || continue
        _check_energy_limit_series(sys, model, first(intervals), length(intervals))
    end
    return
end


# Throws unless every available device of `model` carries finite, non-negative energy-limit series.
function _check_energy_limit_series(sys, model::PSI.DeviceModel, initial_time, n_intervals)
    for d in PSI.get_available_components(model, sys)
        name = PSY.get_name(d)
        names, uigf, remedy = _energy_limit_series(d)
        for key in names
            PSY.has_time_series(d, PSY.SingleTimeSeries, key) || throw(ArgumentError("$name: missing $key; $remedy"))
            values = PSY.get_time_series_values(PSY.SingleTimeSeries, d, key; start_time = initial_time, len = n_intervals, ignore_scaling_factors = true)
            _require_valid_input(name, values, key)
        end
        isnothing(uigf) || _require_valid_input(name, (IS.get_time_series_values(d, uigf; start_time = initial_time, len = n_intervals)::Vector{Float64}), "UIGF")
    end
    return
end


# Throws unless every entry of `values` is finite and non-negative.
function _require_valid_input(name::AbstractString, values, label::AbstractString)
    bad = findfirst(v -> !isfinite(v) || v < 0, values)
    isnothing(bad) || throw(ArgumentError("$name at interval $bad: invalid $label"))
    return
end


# The energy-availability series names a device's dispatch reads, its UIGF key (`nothing` unless
# semi-scheduled), and the remedy for a missing series.
function _energy_limit_series(d::PSY.Storage)
    names = [
        _availability_series_name(d, PSI.ActivePowerOutTimeSeriesParameter),
        _availability_series_name(d, PSI.ActivePowerInTimeSeriesParameter),
    ]
    return names, nothing, _SETTER_REMEDY
end

function _energy_limit_series(d)
    names = [_availability_series_name(d, EnergyLimitTimeSeriesParameter)]
    if !is_semi_scheduled(d)
        return names, nothing, _SETTER_REMEDY
    end
    uigf = AustralianElectricityMarkets.get_telemetry(d).uigf
    isnothing(uigf) && throw(ArgumentError("$(PSY.get_name(d)): semi-scheduled but has no UIGF; call set_unit_conditions!"))
    return names, uigf, _SETTER_REMEDY
end
