# First `(t, floor, ceiling)` whose ramp-down floor `initial - down_rate * minutes` is above the ceiling, or `nothing`.
function _first_envelope_violation(initial, down_rate, ceiling, minutes)
    for t in eachindex(initial)
        floor_pu = initial[t] - down_rate[t] * minutes
        floor_pu > ceiling[t] + _RAMP_FLOOR_TOLERANCE && return (t, floor_pu, ceiling[t])
    end
    return nothing
end


function _envelope_problem(name, t, floor_pu, ceiling_pu)
    return "$name at interval $t: ramp-down floor $floor_pu exceeds availability $ceiling_pu"
end


function _throw_envelope_problems(problems::Vector{String})
    if !isempty(problems)
        throw(
            ArgumentError(
                "NEMDispatch: inconsistent dispatch envelope for $(length(problems)) device(s):\n  " *
                    join(problems, "\n  "),
            ),
        )
    end
    return
end


"""
    check_dispatch_envelope(sys, template, initial_time, n_intervals) -> Nothing

Verifies that no available device `template` models under [`NEMReplayDispatch`](@ref), batteries
excepted, has a ramp-down floor (`"initial_mw"` minus `"ramp_down_rate"` times the series resolution) above its
`"max_active_power"` availability in any of the `n_intervals` intervals from `initial_time`, reading the
`SingleTimeSeries` of `sys` in system-base per-unit.

# Arguments
- `sys`: the `PSY.System` whose series are read.
- `template`: the `PSI.ProblemTemplate` whose `NEMReplayDispatch` device models are checked.
- `initial_time`: the first interval of the simulation.
- `n_intervals`: the number of intervals to check from `initial_time`.

# Returns
`nothing`; throws `ArgumentError` naming each inconsistent device and its first interval.
"""
function check_dispatch_envelope(sys::PSY.System, template::PSI.ProblemTemplate, initial_time::DateTime, n_intervals::Integer)
    params = (InitialPowerTimeSeriesParameter, RampDownRateTimeSeriesParameter, PSI.ActivePowerTimeSeriesParameter)
    problems = String[]
    PSY.with_units_base(sys, PSY.UnitSystem.SYSTEM_BASE) do
        for model in values(PSI.get_device_models(template))
            PSI.get_formulation(model) === NEMReplayDispatch || continue
            PSI.get_component_type(model) <: PSY.Storage && continue
            names = PSI.get_time_series_names(model)
            haskey(names, InitialPowerTimeSeriesParameter) || continue
            for d in PSI.get_available_components(model, sys)
                all(P -> PSY.has_time_series(d, PSY.SingleTimeSeries, names[P]), params) || continue
                initial, down_rate, ceiling = (
                    PSY.get_time_series_values(
                        PSY.SingleTimeSeries, d, names[P]; start_time = initial_time,
                        len = n_intervals, ignore_scaling_factors = true,
                    ) .* PSI.get_multiplier_value(P(), d, NEMReplayDispatch())
                        for P in params
                )
                resolution = IS.get_resolution(PSY.get_time_series(PSY.SingleTimeSeries, d, names[InitialPowerTimeSeriesParameter]))
                minutes = Dates.value(Dates.Minute(resolution))
                hit = _first_envelope_violation(initial, down_rate, ceiling, minutes)
                isnothing(hit) || push!(problems, _envelope_problem(PSY.get_name(d), hit...))
            end
        end
        return
    end
    _throw_envelope_problems(problems)
    return
end
