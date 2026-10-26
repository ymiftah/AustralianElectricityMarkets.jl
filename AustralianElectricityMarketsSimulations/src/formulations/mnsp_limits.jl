const _MNSP_OPERATING_SERIES = (
    MNSPInitialFlowParameter => "mnsp_initial_flow",
    MNSPForwardRampRateParameter => "mnsp_forward_ramp_rate",
    MNSPReverseRampRateParameter => "mnsp_reverse_ramp_rate",
    MNSPForwardFixedLoadParameter => "mnsp_forward_fixed_load",
    MNSPReverseFixedLoadParameter => "mnsp_reverse_fixed_load",
    MNSPForwardFixedLoadInvokedParameter => "mnsp_forward_fixed_load_invoked",
    MNSPReverseFixedLoadInvokedParameter => "mnsp_reverse_fixed_load_invoked",
)

const _MNSP_DIRECTIONAL_SLACKS = (
    MNSPMaxAvailSlack => MNSP_AVAILABILITY_CVP_FACTOR,
    MNSPOfferSlack => MNSP_OFFER_CVP_FACTOR,
    MNSPFixedLoadSurplusSlack => FIXED_LOADING_CVP_FACTOR,
    MNSPFixedLoadDeficitSlack => FIXED_LOADING_CVP_FACTOR,
)

function PSI.get_multiplier_value(::MNSPOperatingParameter, ::PSY.AreaInterchange, ::NEMInterconnectorLoss)
    return 1.0
end

"""
    _add_mnsp_limit_variables!(container, devices)

Allocates non-negative per-unit MW violations for MNSP commercial limits, fixed loading and
net-flow ramping. Directional variables use the link direction as their container meta.

# Returns
`nothing`.
"""
function _add_mnsp_limit_variables!(container, devices)
    names = PSY.get_name.(devices)
    steps = PSI.get_time_steps(container)
    for dir in _MNSP_DIRECTIONS, (V, _) in _MNSP_DIRECTIONAL_SLACKS
        _add_slack_variables!(container, V, PSY.AreaInterchange, names, steps; meta = dir, label = "$(nameof(V))_$dir")
    end
    for V in (MNSPRampUpSlack, MNSPRampDownSlack)
        _add_slack_variables!(container, V, PSY.AreaInterchange, names, steps)
    end
    return
end

"""
    _add_mnsp_operating_constraints!(container, devices)

Adds signed net-flow ramp limits about metered flow and directional fixed-loading rows for
MNSPs. Natural MW and MW/min inputs are converted to the container's per-unit interval limits.

# Returns
`nothing`.
"""
function _add_mnsp_operating_constraints!(container, devices)
    mnsp = filter(_has_mnsp_offers, collect(devices))
    isempty(mnsp) && return
    T = PSY.AreaInterchange
    names, steps = PSY.get_name.(mnsp), PSI.get_time_steps(container)
    base = PSI.get_base_power(container)
    minutes = 60 * interval_hours(PSI.get_resolution(container))
    initial, _ = _ts_parameter_accessor(container, MNSPInitialFlowParameter, T)
    up_rate, _ = _ts_parameter_accessor(container, MNSPForwardRampRateParameter, T)
    down_rate, _ = _ts_parameter_accessor(container, MNSPReverseRampRateParameter, T)
    flow = PSI.get_variable(container, PSI.FlowActivePowerVariable(), T)
    up = PSI.get_variable(container, MNSPRampUpSlack(), T)
    down = PSI.get_variable(container, MNSPRampDownSlack(), T)
    jm = PSI.get_jump_model(container)
    upper = PSI.add_constraints_container!(container, MNSPRampConstraint(), T, names, steps; meta = "up")
    lower = PSI.add_constraints_container!(container, MNSPRampConstraint(), T, names, steps; meta = "down")
    for name in names, t in steps
        upper[name, t] = JuMP.@constraint(jm, flow[name, t] - up[name, t] <= (initial(name, t) + minutes * up_rate(name, t)) / base)
        lower[name, t] = JuMP.@constraint(jm, flow[name, t] + down[name, t] >= (initial(name, t) - minutes * down_rate(name, t)) / base)
    end
    links = PSI.get_variable(container, MNSPLinkFlowVariable(), T)
    for (dir, target_type, invoked_type) in (
            ("forward", MNSPForwardFixedLoadParameter, MNSPForwardFixedLoadInvokedParameter),
            ("reverse", MNSPReverseFixedLoadParameter, MNSPReverseFixedLoadInvokedParameter),
        )
        target, _ = _ts_parameter_accessor(container, target_type, T)
        invoked, _ = _ts_parameter_accessor(container, invoked_type, T)
        surplus = PSI.get_variable(container, MNSPFixedLoadSurplusSlack(), T, dir)
        deficit = PSI.get_variable(container, MNSPFixedLoadDeficitSlack(), T, dir)
        upper = PSI.add_constraints_container!(container, MNSPFixedLoadConstraint(), T, names, steps; meta = "$(dir)_upper")
        lower = PSI.add_constraints_container!(container, MNSPFixedLoadConstraint(), T, names, steps; meta = "$(dir)_lower")
        for device in mnsp, t in steps
            name = PSY.get_name(device)
            relax = _mnsp_link_bound(device, dir) * (1.0 - invoked(name, t))
            upper[name, t] = JuMP.@constraint(jm, links[name, dir, t] - surplus[name, t] <= target(name, t) / base + relax)
            lower[name, t] = JuMP.@constraint(jm, links[name, dir, t] + deficit[name, t] >= target(name, t) / base - relax)
        end
    end
    return
end

"""
    _add_mnsp_limit_costs!(container, devices)

Prices MNSP violations at their CVP factors times each interval's Market Price Cap, base power
and interval duration. Registered MPC parameters update the costs during recurrent solves.

# Returns
`nothing`.
"""
function _add_mnsp_limit_costs!(container, devices)
    names = PSY.get_name.(devices)
    for dir in _MNSP_DIRECTIONS, (V, factor) in _MNSP_DIRECTIONAL_SLACKS
        _add_mpc_penalty!(container, V, PSY.AreaInterchange, names, factor; meta = dir)
    end
    for V in (MNSPRampUpSlack, MNSPRampDownSlack)
        _add_mpc_penalty!(container, V, PSY.AreaInterchange, names, MNSP_RAMP_CVP_FACTOR)
    end
    return
end
