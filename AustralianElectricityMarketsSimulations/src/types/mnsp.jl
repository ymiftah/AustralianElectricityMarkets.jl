# MNSP link offers on a `PSY.AreaInterchange` under `NEMInterconnectorLoss`: the interconnector's net
# flow is split into a forward and a reverse link flow, each priced by its own offer and elastic commercial limits.

"""
    MNSPLinkFlowVariable

One MNSP link's flow at one timestep, non-negative and per-unit of the system base. Indexed
`(interconnector name, "forward" | "reverse", t)`; the forward link carries flow from the
interconnector's from area to its to area.
"""
struct MNSPLinkFlowVariable <: PSI.VariableType end


"""
    MNSPLinkConstraint

Row over one MNSP link or interconnector, per-unit. The key meta names the row, and a composite meta
continues after its first `|`:

- `"flow"`: `flow[ic,t] == forward link flow - reverse link flow`, indexed `(interconnector name, t)`.
- `"band"`: `Σ bands + offer surplus == link flow`, indexed `(interconnector name, "forward" | "reverse", t)`.
- `"max_avail"`: `link flow - availability surplus <= MAXAVAIL`, indexed as `"band"`.
- `"direction"`: `link flow <= bound * on`, where `on` is [`MNSPLinkDirectionVariable`](@ref) for the forward
  link and its complement for the reverse link, indexed as `"band"`.
- `"loss|lb"` and `"loss|ub"`: bound one link's [`MNSPLinkLossVariable`](@ref) to zero when the link is inactive,
  `loss >= lower * on` and `loss <= upper * on`, indexed as `"band"`.
- `"loss_split"`: `forward loss + reverse loss == interconnector loss`, indexed `(interconnector name, t)`.
- `"ramp|up"` and `"ramp|down"`: the signed net-flow ramp limit about metered starting flow, indexed
  `(interconnector name, t)`.
- `"fixed_load|<link>_upper"` and `"fixed_load|<link>_lower"`: the link's fixed-loading limit, with the
  [`MNSPSlack`](@ref) surplus or deficit it relaxes, indexed `(interconnector name, t)`.
"""
struct MNSPLinkConstraint <: PSI.ConstraintType end


"""
    MNSPLinkDirectionVariable

Binary per interconnector and timestep, `1` when only the forward link may flow and `0` when only
the reverse link may, so the two links never flow at once.
"""
struct MNSPLinkDirectionVariable <: PSI.VariableType end


"""
    MNSPLinkLossVariable

DC losses supplied by one directional MNSP link's sending area, per-unit of the system base.
Indexed `(interconnector name, "forward" | "reverse", t)`; the two directions sum to the
interconnector's total loss, and only the active direction is nonzero.
"""
struct MNSPLinkLossVariable <: PSI.VariableType end

PSI.convert_result_to_natural_units(::Type{MNSPLinkLossVariable}) = true


"""
    MNSPLinkBandVariable

One MNSP link's flow in one offer band at one timestep, non-negative and per-unit of the system
base. Indexed `(interconnector name, band label, t)` with meta `"forward"` or `"reverse"`; the band
axis is sized to the most bands any link offers over the system's series, and a band a link does
not offer at an interval has zero width.
"""
struct MNSPLinkBandVariable <: PSI.VariableType end

PSI.convert_result_to_natural_units(::Type{MNSPLinkBandVariable}) = true


"""
    MNSPBandWidthParameter

Time-series parameter of an MNSP link's offered band widths, in MW, read from its
`"link_<direction>_offer"` series with a band axis; bands beyond an interval's offer have width
`0.0`. Meta `"forward"` or `"reverse"` names the link.
"""
struct MNSPBandWidthParameter <: PSI.TimeSeriesParameter end


"""
    MNSPMaxAvailParameter

Time-series parameter of an MNSP link's `MAXAVAIL`, in MW, read from its
`"link_<direction>_max_avail"` series. Meta `"forward"` or `"reverse"` names the link.
"""
struct MNSPMaxAvailParameter <: PSI.TimeSeriesParameter end


"""
    MNSPBandPriceParameter

Time-series cost parameter pricing an MNSP link's [`MNSPLinkBandVariable`](@ref)s: its value is
each band's offer price in `\$/MWh` per interval, read from the link's `"link_<direction>_offer"`
series (`0.0` for a band not offered). Each band's cost target scales the price by the system base
power and the interval length in hours. Meta `"forward"` or `"reverse"`.
"""
struct MNSPBandPriceParameter <: PSI.TimeSeriesCostParameter end
