"""
    NEM_MNSP_FIXED_LOAD_SERIES

Names of the NaN-free fixed-loading series that [`set_effective_offers!`](@ref) derives per MNSP link direction from
the bid's `fixed_load`: `value` is the loading in MW, `0` where the bid is NULL, and `invoked` is `1` where a
loading is published and `0` where it is NULL.
"""
const NEM_MNSP_FIXED_LOAD_SERIES = (
    forward_value = "forward_fixed_load_value",
    reverse_value = "reverse_fixed_load_value",
    forward_invoked = "forward_fixed_load_invoked_flag",
    reverse_invoked = "reverse_fixed_load_invoked_flag",
)

"Time-series parameter of an MNSP operating input in natural units."
abstract type MNSPOperatingParameter <: PSI.TimeSeriesParameter end

"""
    MNSPInitialFlowParameter

Signed metered starting flow, in MW, from the [`NEMMNSPObservedState`](@ref) key `NEM_MNSP_SERIES.initial_flow`.
"""
struct MNSPInitialFlowParameter <: MNSPOperatingParameter end

"""
    MNSPForwardRampRateParameter

Forward link ramp rate, in MW/min, from the forward bid's `ramp_up` key.
"""
struct MNSPForwardRampRateParameter <: MNSPOperatingParameter end

"""
    MNSPReverseRampRateParameter

Reverse link ramp rate, in MW/min, from the reverse bid's `ramp_up` key, which limits the net flow's decrease.
"""
struct MNSPReverseRampRateParameter <: MNSPOperatingParameter end

"""
    MNSPForwardFixedLoadParameter

Forward link fixed loading, in MW, from the forward bid's `fixed_load` key.
"""
struct MNSPForwardFixedLoadParameter <: MNSPOperatingParameter end

"""
    MNSPReverseFixedLoadParameter

Reverse link fixed loading, in MW, from the reverse bid's `fixed_load` key.
"""
struct MNSPReverseFixedLoadParameter <: MNSPOperatingParameter end

"""
    MNSPForwardFixedLoadInvokedParameter

Forward fixed-loading invocation flag, from the forward bid's `fixed_load_invoked` key.
"""
struct MNSPForwardFixedLoadInvokedParameter <: MNSPOperatingParameter end

"""
    MNSPReverseFixedLoadInvokedParameter

Reverse fixed-loading invocation flag, from the reverse bid's `fixed_load_invoked` key.
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
