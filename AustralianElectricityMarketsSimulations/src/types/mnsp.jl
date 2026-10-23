# MNSP link offers on a `PSY.AreaInterchange` under `NEMInterconnectorLoss`: the interconnector's net
# flow is split into a forward and a reverse link flow, each bounded and priced by its own offer.

"""
    MNSPLinkFlowVariable

One MNSP link's flow at one timestep, non-negative and per-unit of the system base. Indexed
`(interconnector name, "forward" | "reverse", t)`; the forward link carries flow from the
interconnector's from area to its to area.
"""
struct MNSPLinkFlowVariable <: PSI.VariableType end


"""
    MNSPLinkFlowConstraint

`flow[ic,t] == forward link flow - reverse link flow`, per-unit.
"""
struct MNSPLinkFlowConstraint <: PSI.ConstraintType end


"""
    MNSPLinkBandConstraint

`Σ bands == link flow` for one MNSP link, per-unit. Indexed `(interconnector name, "forward" | "reverse", t)`.
"""
struct MNSPLinkBandConstraint <: PSI.ConstraintType end


"""
    MNSPLinkMaxAvailConstraint

`link flow <= MAXAVAIL` for one MNSP link, per-unit. Indexed `(interconnector name, "forward" | "reverse", t)`.
"""
struct MNSPLinkMaxAvailConstraint <: PSI.ConstraintType end


"""
    MNSPLinkDirectionConstraint

`link flow <= bound * on`, where `on` is [`MNSPLinkDirectionVariable`](@ref) for the forward link
and its complement for the reverse link. Indexed `(interconnector name, "forward" | "reverse", t)`.
"""
struct MNSPLinkDirectionConstraint <: PSI.ConstraintType end


"""
    MNSPLinkLossConstraint

Bounds one link's [`MNSPLinkLossVariable`](@ref) to zero when the link is inactive: `meta = "lb"`
holds `loss >= lower * on` and `meta = "ub"` holds `loss <= upper * on`. Indexed
`(interconnector name, "forward" | "reverse", t)`.
"""
struct MNSPLinkLossConstraint <: PSI.ConstraintType end


"""
    MNSPLinkLossSplitConstraint

`forward loss + reverse loss == interconnector loss`, per-unit.
"""
struct MNSPLinkLossSplitConstraint <: PSI.ConstraintType end


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
`"mnsp_<direction>_offer"` series with a band axis; bands beyond an interval's offer have width
`0.0`. [`MNSPForwardBandWidthParameter`](@ref) and [`MNSPReverseBandWidthParameter`](@ref) are the
two links.
"""
abstract type MNSPBandWidthParameter <: PSI.TimeSeriesParameter end

"[`MNSPBandWidthParameter`](@ref) of the forward link."
struct MNSPForwardBandWidthParameter <: MNSPBandWidthParameter end

"[`MNSPBandWidthParameter`](@ref) of the reverse link."
struct MNSPReverseBandWidthParameter <: MNSPBandWidthParameter end


"""
    MNSPMaxAvailParameter

Time-series parameter of an MNSP link's `MAXAVAIL`, in MW, read from its
`"mnsp_<direction>_max_avail"` series. [`MNSPForwardMaxAvailParameter`](@ref) and
[`MNSPReverseMaxAvailParameter`](@ref) are the two links.
"""
abstract type MNSPMaxAvailParameter <: PSI.TimeSeriesParameter end

"[`MNSPMaxAvailParameter`](@ref) of the forward link."
struct MNSPForwardMaxAvailParameter <: MNSPMaxAvailParameter end

"[`MNSPMaxAvailParameter`](@ref) of the reverse link."
struct MNSPReverseMaxAvailParameter <: MNSPMaxAvailParameter end


"""
    MNSPBandPriceParameter

Objective-function parameter pricing an MNSP link's [`MNSPLinkBandVariable`](@ref)s: its value is
each band's offer price in `\$/MWh` per interval (`0.0` for a band not offered) and its multiplier
the system base power times the interval length in hours. Meta `"forward"` or `"reverse"`.
"""
struct MNSPBandPriceParameter <: PSI.ObjectiveFunctionParameter end
