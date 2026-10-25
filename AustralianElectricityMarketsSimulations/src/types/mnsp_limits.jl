"Time-series parameter of an MNSP operating input in natural units."
abstract type MNSPOperatingParameter <: PSI.TimeSeriesParameter end

"""
    MNSPInitialFlowParameter

Signed metered starting flow, in MW, from the `"mnsp_initial_flow"` series.
"""
struct MNSPInitialFlowParameter <: MNSPOperatingParameter end

"""
    MNSPForwardRampRateParameter

Forward link ramp rate, in MW/min, from `"mnsp_forward_ramp_rate"`.
"""
struct MNSPForwardRampRateParameter <: MNSPOperatingParameter end

"""
    MNSPReverseRampRateParameter

Reverse link ramp rate, in MW/min, from `"mnsp_reverse_ramp_rate"`.
"""
struct MNSPReverseRampRateParameter <: MNSPOperatingParameter end

"""
    MNSPForwardFixedLoadParameter

Forward link fixed loading, in MW, from `"mnsp_forward_fixed_load"`.
"""
struct MNSPForwardFixedLoadParameter <: MNSPOperatingParameter end

"""
    MNSPReverseFixedLoadParameter

Reverse link fixed loading, in MW, from `"mnsp_reverse_fixed_load"`.
"""
struct MNSPReverseFixedLoadParameter <: MNSPOperatingParameter end

"""
    MNSPForwardFixedLoadInvokedParameter

Forward fixed-loading invocation flag, from `"mnsp_forward_fixed_load_invoked"`.
"""
struct MNSPForwardFixedLoadInvokedParameter <: MNSPOperatingParameter end

"""
    MNSPReverseFixedLoadInvokedParameter

Reverse fixed-loading invocation flag, from `"mnsp_reverse_fixed_load_invoked"`.
"""
struct MNSPReverseFixedLoadInvokedParameter <: MNSPOperatingParameter end

"Non-negative violation of an MNSP operating constraint."
abstract type AbstractMNSPSlack <: PSI.VariableType end

"""
    MNSPMaxAvailSlack

Non-negative excess over an MNSP link's availability, in system-base per-unit MW.
"""
struct MNSPMaxAvailSlack <: AbstractMNSPSlack end

"""
    MNSPOfferSlack

Non-negative MNSP flow above cleared offered bands, in system-base per-unit MW.
"""
struct MNSPOfferSlack <: AbstractMNSPSlack end

"""
    MNSPRampUpSlack

Non-negative excess over the forward net-flow ramp limit, in system-base per-unit MW.
"""
struct MNSPRampUpSlack <: AbstractMNSPSlack end

"""
    MNSPRampDownSlack

Non-negative shortfall below the reverse net-flow ramp limit, in system-base per-unit MW.
"""
struct MNSPRampDownSlack <: AbstractMNSPSlack end

"""
    MNSPFixedLoadSurplusSlack

Non-negative excess over a link's fixed-loading target, in system-base per-unit MW.
"""
struct MNSPFixedLoadSurplusSlack <: AbstractMNSPSlack end

"""
    MNSPFixedLoadDeficitSlack

Non-negative shortfall below a link's fixed-loading target, in system-base per-unit MW.
"""
struct MNSPFixedLoadDeficitSlack <: AbstractMNSPSlack end

"""
    MNSPRampConstraint

Signed net-flow ramp limit about metered starting flow; meta is `"up"` or `"down"`.
"""
struct MNSPRampConstraint <: PSI.ConstraintType end

"""
    MNSPFixedLoadConstraint

Directional fixed-loading limit with a priced violation; meta identifies the link and sense.
"""
struct MNSPFixedLoadConstraint <: PSI.ConstraintType end
