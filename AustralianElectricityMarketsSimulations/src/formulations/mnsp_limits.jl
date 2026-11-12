# The meta of each `MNSPOperatingParameter` to the series it reads.
const _MNSP_OPERATING_SERIES = (
    _mnsp_input_meta(MNSPInitialFlowInput()) => NEM_MNSP_SERIES.initial_flow,
    _mnsp_input_meta(MNSPRampRateInput(), MNSPForwardLink()) => NEM_MNSP_SERIES.forward_ramp_rate,
    _mnsp_input_meta(MNSPRampRateInput(), MNSPReverseLink()) => NEM_MNSP_SERIES.reverse_ramp_rate,
    _mnsp_input_meta(MNSPFixedLoadInput(), MNSPForwardLink()) => NEM_MNSP_FIXED_LOAD_SERIES.forward_value,
    _mnsp_input_meta(MNSPFixedLoadInput(), MNSPReverseLink()) => NEM_MNSP_FIXED_LOAD_SERIES.reverse_value,
    _mnsp_input_meta(MNSPFixedLoadInvokedInput(), MNSPForwardLink()) => NEM_MNSP_FIXED_LOAD_SERIES.forward_invoked,
    _mnsp_input_meta(MNSPFixedLoadInvokedInput(), MNSPReverseLink()) => NEM_MNSP_FIXED_LOAD_SERIES.reverse_invoked,
)

const _MNSP_LINKS = (MNSPForwardLink(), MNSPReverseLink())
const _MNSP_DIRECTIONAL_VARIANTS = (
    MNSPMaxAvailVariant(), MNSPOfferVariant(), MNSPFixedLoadSurplusVariant(), MNSPFixedLoadDeficitVariant(),
)
const _MNSP_RAMP_VARIANTS = (MNSPRampUpVariant(), MNSPRampDownVariant())

# The name each MNSP slack variant had as its own type, kept as the base name of its variables.
_mnsp_slack_name(::MNSPMaxAvailVariant) = "MNSPMaxAvailSlack"
_mnsp_slack_name(::MNSPOfferVariant) = "MNSPOfferSlack"
_mnsp_slack_name(::MNSPRampUpVariant) = "MNSPRampUpSlack"
_mnsp_slack_name(::MNSPRampDownVariant) = "MNSPRampDownSlack"
_mnsp_slack_name(::MNSPFixedLoadSurplusVariant) = "MNSPFixedLoadSurplusSlack"
_mnsp_slack_name(::MNSPFixedLoadDeficitVariant) = "MNSPFixedLoadDeficitSlack"

# The AEMO CVP factor each MNSP slack variant is priced at.
_mnsp_slack_cvp(::MNSPMaxAvailVariant) = MNSP_AVAILABILITY_CVP_FACTOR
_mnsp_slack_cvp(::MNSPOfferVariant) = MNSP_OFFER_CVP_FACTOR
_mnsp_slack_cvp(::_MNSPRampVariant) = MNSP_RAMP_CVP_FACTOR
_mnsp_slack_cvp(::_MNSPFixedLoadVariant) = FIXED_LOADING_CVP_FACTOR

function PSI.get_multiplier_value(::MNSPOperatingParameter, ::PSY.AreaInterchange, ::NEMInterconnectorLoss)
    return 1.0
end

# The accessor of the `MNSPOperatingParameter` of the given input kind (and link, for a directional kind).
function _mnsp_input_accessor(container, kind::_MNSPInputKind, link...)
    return _ts_parameter_accessor(container, MNSPOperatingParameter, PSY.AreaInterchange, _mnsp_input_meta(kind, link...))
end

"""
    _add_mnsp_limit_variables!(container, devices)

Allocates non-negative per-unit MW violations for MNSP commercial limits, fixed loading and
net-flow ramping, as [`MNSPSlack`](@ref) variables keyed by their variant and, for the directional
variants, their link.

# Returns
`nothing`.
"""
function _add_mnsp_limit_variables!(container, devices)
    names = PSY.get_name.(devices)
    steps = PSI.get_time_steps(container)
    for link in _MNSP_LINKS, v in _MNSP_DIRECTIONAL_VARIANTS
        label = "$(_mnsp_slack_name(v))_$(_mnsp_link_prefix(link))"
        _add_slack_variables!(container, MNSPSlack, PSY.AreaInterchange, names, steps; meta = _mnsp_slack_meta(v, link), label)
    end
    for v in _MNSP_RAMP_VARIANTS
        _add_slack_variables!(container, MNSPSlack, PSY.AreaInterchange, names, steps; meta = _mnsp_slack_meta(v), label = _mnsp_slack_name(v))
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
    initial, _ = _mnsp_input_accessor(container, MNSPInitialFlowInput())
    up_rate, _ = _mnsp_input_accessor(container, MNSPRampRateInput(), MNSPForwardLink())
    down_rate, _ = _mnsp_input_accessor(container, MNSPRampRateInput(), MNSPReverseLink())
    flow = PSI.get_variable(container, PSI.FlowActivePowerVariable(), T)
    up = PSI.get_variable(container, MNSPSlack(), T, _mnsp_slack_meta(MNSPRampUpVariant()))
    down = PSI.get_variable(container, MNSPSlack(), T, _mnsp_slack_meta(MNSPRampDownVariant()))
    jm = PSI.get_jump_model(container)
    upper = PSI.add_constraints_container!(container, MNSPLinkConstraint(), T, names, steps; meta = "ramp|up")
    lower = PSI.add_constraints_container!(container, MNSPLinkConstraint(), T, names, steps; meta = "ramp|down")
    for name in names, t in steps
        upper[name, t] = JuMP.@constraint(jm, flow[name, t] - up[name, t] <= (initial(name, t) + minutes * up_rate(name, t)) / base)
        lower[name, t] = JuMP.@constraint(jm, flow[name, t] + down[name, t] >= (initial(name, t) - minutes * down_rate(name, t)) / base)
    end
    links = PSI.get_variable(container, MNSPLinkFlowVariable(), T)
    for (dir, link) in (("forward", MNSPForwardLink()), ("reverse", MNSPReverseLink()))
        target, _ = _mnsp_input_accessor(container, MNSPFixedLoadInput(), link)
        invoked, _ = _mnsp_input_accessor(container, MNSPFixedLoadInvokedInput(), link)
        surplus = PSI.get_variable(container, MNSPSlack(), T, _mnsp_slack_meta(MNSPFixedLoadSurplusVariant(), link))
        deficit = PSI.get_variable(container, MNSPSlack(), T, _mnsp_slack_meta(MNSPFixedLoadDeficitVariant(), link))
        upper = PSI.add_constraints_container!(container, MNSPLinkConstraint(), T, names, steps; meta = "fixed_load|$(dir)_upper")
        lower = PSI.add_constraints_container!(container, MNSPLinkConstraint(), T, names, steps; meta = "fixed_load|$(dir)_lower")
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

Prices MNSP violations at their CVP factors times the Market Price Cap of the build's initial interval,
base power and interval duration.

# Returns
`nothing`.
"""
function _add_mnsp_limit_costs!(container, devices)
    names = PSY.get_name.(devices)
    for link in _MNSP_LINKS, v in _MNSP_DIRECTIONAL_VARIANTS
        _add_mpc_penalty!(container, MNSPSlack, PSY.AreaInterchange, names, _mnsp_slack_cvp(v); meta = _mnsp_slack_meta(v, link))
    end
    for v in _MNSP_RAMP_VARIANTS
        _add_mpc_penalty!(container, MNSPSlack, PSY.AreaInterchange, names, _mnsp_slack_cvp(v); meta = _mnsp_slack_meta(v))
    end
    return
end
