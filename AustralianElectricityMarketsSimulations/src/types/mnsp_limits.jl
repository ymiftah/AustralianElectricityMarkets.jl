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

"""
    MNSPSlack

Non-negative violation of an MNSP operating constraint, in system-base per-unit MW. The key meta names the
variant, followed by its link direction for the commercial limits and fixed loading:

- `"max_avail|<link>"`: excess over the link's availability.
- `"offer|<link>"`: flow above the cleared offered bands.
- `"ramp|up"` or `"ramp|down"`: excess over, or shortfall below, the net-flow ramp limit.
- `"fixed_load|surplus|<link>"` or `"fixed_load|deficit|<link>"`: excess over, or shortfall below, the
  link's fixed-loading target.

The link is `"forward"` or `"reverse"`.
"""
struct MNSPSlack <: PSI.VariableType end

struct MNSPMaxAvailVariant end
struct MNSPOfferVariant end
struct MNSPRampUpVariant end
struct MNSPRampDownVariant end
struct MNSPFixedLoadSurplusVariant end
struct MNSPFixedLoadDeficitVariant end

const _MNSPRampVariant = Union{MNSPRampUpVariant, MNSPRampDownVariant}
const _MNSPFixedLoadVariant = Union{MNSPFixedLoadSurplusVariant, MNSPFixedLoadDeficitVariant}

# The variant's own segments of the meta, before any link direction.
_mnsp_slack_head(::MNSPMaxAvailVariant) = "max_avail"
_mnsp_slack_head(::MNSPOfferVariant) = "offer"
_mnsp_slack_head(::MNSPRampUpVariant) = "ramp|up"
_mnsp_slack_head(::MNSPRampDownVariant) = "ramp|down"
_mnsp_slack_head(::MNSPFixedLoadSurplusVariant) = "fixed_load|surplus"
_mnsp_slack_head(::MNSPFixedLoadDeficitVariant) = "fixed_load|deficit"

# The key meta of a ramp variant, and of a directional variant on its link.
_mnsp_slack_meta(v::_MNSPRampVariant) = _mnsp_slack_head(v)
_mnsp_slack_meta(v::Union{MNSPMaxAvailVariant, MNSPOfferVariant, _MNSPFixedLoadVariant}, link::Union{MNSPForwardLink, MNSPReverseLink}) =
    string(_mnsp_slack_head(v), "|", _mnsp_link_prefix(link))

# Splits a meta at its first `|` into its first segment and the rest, which is empty when there is none.
function _split_mnsp_meta(meta::AbstractString)
    parts = split(meta, '|'; limit = 2)
    return String(parts[1]), length(parts) == 2 ? String(parts[2]) : ""
end

# The ramp variant a meta after `ramp|` names.
function _mnsp_ramp_variant(meta::AbstractString)::_MNSPRampVariant
    sense, _ = _split_mnsp_meta(meta)
    sense == "up" && return MNSPRampUpVariant()
    sense == "down" && return MNSPRampDownVariant()
    throw(ArgumentError("an MNSPSlack ramp names \"up\" or \"down\", got \"$sense\""))
end

# The fixed-loading variant a meta after `fixed_load|` names.
function _mnsp_fixed_load_variant(meta::AbstractString)::_MNSPFixedLoadVariant
    sense, _ = _split_mnsp_meta(meta)
    sense == "surplus" && return MNSPFixedLoadSurplusVariant()
    sense == "deficit" && return MNSPFixedLoadDeficitVariant()
    throw(ArgumentError("an MNSPSlack fixed load names \"surplus\" or \"deficit\", got \"$sense\""))
end

# The variant an `MNSPSlack` meta names: its kind, then its ramp direction or fixed-loading sense.
function _mnsp_slack_variant(meta::String)::Union{MNSPMaxAvailVariant, MNSPOfferVariant, _MNSPRampVariant, _MNSPFixedLoadVariant}
    kind, rest = _split_mnsp_meta(meta)
    kind == "max_avail" && return MNSPMaxAvailVariant()
    kind == "offer" && return MNSPOfferVariant()
    kind == "ramp" && return _mnsp_ramp_variant(rest)
    kind == "fixed_load" && return _mnsp_fixed_load_variant(rest)
    throw(ArgumentError("an MNSPSlack has no variant named \"$kind\""))
end

# The link tag of a link direction name, `"forward"` or `"reverse"`.
function _mnsp_direction_link(dir::AbstractString)::Union{MNSPForwardLink, MNSPReverseLink}
    dir == "forward" && return MNSPForwardLink()
    dir == "reverse" && return MNSPReverseLink()
    throw(ArgumentError("an MNSP link direction is \"forward\" or \"reverse\", got \"$dir\""))
end

# The link direction a directional `MNSPSlack` meta names, its last segment.
_mnsp_slack_link(meta::String) = _mnsp_direction_link(last(split(meta, '|')))
