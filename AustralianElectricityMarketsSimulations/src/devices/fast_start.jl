const PROFILE_CVP_FACTOR = 1130.0
const OFFER_CVP_FACTOR = 1135.0
const AVAILABILITY_CVP_FACTOR = 370.0

PSI.convert_result_to_natural_units(::Type{FastStartProfileDeficitSlack}) = true
PSI.convert_result_to_natural_units(::Type{FastStartProfileSurplusSlack}) = true
PSI.convert_result_to_natural_units(::Type{AvailabilitySurplusSlack}) = true
PSI.convert_result_to_natural_units(::Type{OfferSurplusSlack}) = true

function _fast_start_energy_ramp_envelope(context, duid, t)
    context.pass === :dispatch || return nothing
    return get(context.envelopes, duid, nothing)
end

function _add_fast_start_profile_constraints!(container, devices, context)::Nothing
    context.pass === :dispatch || return nothing
    names = [PSY.get_name(d) for d in devices if haskey(context.envelopes, PSY.get_name(d))]
    isempty(names) && return nothing
    times = PSI.get_time_steps(container)
    jm = PSI.get_jump_model(container)
    power = PSI.get_variable(container, PSI.ActivePowerVariable(), PSY.ThermalStandard)
    base = PSI.get_base_power(container)
    upper_names = [name for name in names if !isnothing(context.envelopes[name].profile_upper_mw)]
    lower = PSI.add_constraints_container!(container, FastStartProfileConstraint(), PSY.ThermalStandard, names, times; meta = "lower")
    upper = isempty(upper_names) ? nothing : PSI.add_constraints_container!(container, FastStartProfileConstraint(), PSY.ThermalStandard, upper_names, times; meta = "upper")
    deficit = _add_cvp_slack!(container, FastStartProfileDeficitSlack, PSY.ThermalStandard, names, times, PROFILE_CVP_FACTOR)
    surplus = isempty(upper_names) ? nothing : _add_cvp_slack!(container, FastStartProfileSurplusSlack, PSY.ThermalStandard, upper_names, times, PROFILE_CVP_FACTOR)
    for name in names, t in times
        envelope = context.envelopes[name]
        value = envelope.profile_lower_mw / base
        lower[name, t] = JuMP.@constraint(jm, power[name, t] + deficit[name, t] >= value)
        if !isnothing(envelope.profile_upper_mw)
            upper[name, t] = JuMP.@constraint(jm, power[name, t] - surplus[name, t] <= envelope.profile_upper_mw / base)
        end
    end
    return nothing
end

function _add_thermal_availability_constraints!(container, devices)
    names = [PSY.get_name(d) for d in devices]
    isempty(names) && return nothing
    times = PSI.get_time_steps(container)
    jm = PSI.get_jump_model(container)
    power = PSI.get_variable(container, PSI.ActivePowerVariable(), PSY.ThermalStandard)
    availability, covered = _ts_parameter_accessor(container, AvailabilityTimeSeriesParameter, PSY.ThermalStandard)
    _require_coverage(names, "no \"availability\" time series", _SETTER_REMEDY, covered)
    slack = _add_cvp_slack!(container, AvailabilitySurplusSlack, PSY.ThermalStandard, names, times, AVAILABILITY_CVP_FACTOR)
    rows = PSI.add_constraints_container!(container, AvailabilityConstraint(), PSY.ThermalStandard, names, times)
    for name in names, t in times
        rows[name, t] = JuMP.@constraint(jm, power[name, t] - slack[name, t] <= availability(name, t))
    end
    return nothing
end

function _add_thermal_offer_excess!(container, devices)
    names = [PSY.get_name(d) for d in devices]
    isempty(names) && return nothing
    times = PSI.get_time_steps(container)
    slack = _add_cvp_slack!(container, OfferSurplusSlack, PSY.ThermalStandard, names, times, OFFER_CVP_FACTOR)
    constraints = PSI.get_constraint(container, PSI.PiecewiseLinearBlockIncrementalOfferConstraint(), PSY.ThermalStandard)
    for name in names, t in times
        JuMP.set_normalized_coefficient(constraints[name, t], slack[name, t], -1.0)
    end
    return nothing
end
