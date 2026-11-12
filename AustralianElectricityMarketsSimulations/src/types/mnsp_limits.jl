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

"""
    MNSPOperatingParameter

Time-series parameter of an MNSP operating input in natural units. The key meta names the input:

- `"initial_flow"`: the signed metered starting flow, in MW, from the [`NEMMNSPObservedState`](@ref) key
  `NEM_MNSP_SERIES.initial_flow`.
- `"forward_ramp_rate"`: the forward link ramp rate, in MW/min, from the forward bid's `ramp_up` key.
- `"reverse_ramp_rate"`: the reverse link ramp rate, in MW/min, from the reverse bid's `ramp_up` key,
  which limits the net flow's decrease.
- `"forward_fixed_load"` and `"reverse_fixed_load"`: the link's fixed loading, in MW, read from the
  `NEM_MNSP_FIXED_LOAD_SERIES` `value` series that [`set_effective_offers!`](@ref) derives from the bid's
  `fixed_load`; the bid's raw series holds NaN where AEMO publishes NULL, and the derived series holds `0` there.
- `"forward_fixed_load_invoked"` and `"reverse_fixed_load_invoked"`: the fixed-loading invocation flag, `1`
  where the bid publishes a loading and `0` where it is NULL, read from the `invoked` series that
  [`set_effective_offers!`](@ref) derives.
"""
struct MNSPOperatingParameter <: PSI.TimeSeriesParameter end

# Singleton tags recovered from the meta of an `MNSPOperatingParameter`: the kind of input, and the link
# direction of the three directional kinds.
struct MNSPInitialFlowInput end
struct MNSPRampRateInput end
struct MNSPFixedLoadInput end
struct MNSPFixedLoadInvokedInput end
struct MNSPForwardLink end
struct MNSPReverseLink end

const _MNSPInputKind = Union{MNSPInitialFlowInput, MNSPRampRateInput, MNSPFixedLoadInput, MNSPFixedLoadInvokedInput}

_mnsp_input_suffix(::MNSPRampRateInput) = "ramp_rate"
_mnsp_input_suffix(::MNSPFixedLoadInput) = "fixed_load"
_mnsp_input_suffix(::MNSPFixedLoadInvokedInput) = "fixed_load_invoked"

_mnsp_link_prefix(::MNSPForwardLink) = "forward"
_mnsp_link_prefix(::MNSPReverseLink) = "reverse"

# The meta of an operating input: `"initial_flow"`, or `"<direction>_<kind>"`.
_mnsp_input_meta(::MNSPInitialFlowInput) = "initial_flow"
_mnsp_input_meta(kind::Union{MNSPRampRateInput, MNSPFixedLoadInput, MNSPFixedLoadInvokedInput}, link::Union{MNSPForwardLink, MNSPReverseLink}) =
    string(_mnsp_link_prefix(link), "_", _mnsp_input_suffix(kind))

# The kind of input a meta names.
function _mnsp_input_kind(meta::String)::_MNSPInputKind
    meta == "initial_flow" && return MNSPInitialFlowInput()
    endswith(meta, "_ramp_rate") && return MNSPRampRateInput()
    endswith(meta, "_fixed_load_invoked") && return MNSPFixedLoadInvokedInput()
    endswith(meta, "_fixed_load") && return MNSPFixedLoadInput()
    throw(ArgumentError("an MNSPOperatingParameter has no input named \"$meta\""))
end

# The link direction a directional meta names.
function _mnsp_input_link(meta::String)::Union{MNSPForwardLink, MNSPReverseLink}
    startswith(meta, "forward_") && return MNSPForwardLink()
    startswith(meta, "reverse_") && return MNSPReverseLink()
    throw(ArgumentError("MNSPOperatingParameter meta \"$meta\" names no link direction"))
end

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
