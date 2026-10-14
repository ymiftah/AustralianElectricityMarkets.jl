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
