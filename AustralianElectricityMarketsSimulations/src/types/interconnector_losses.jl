# `PSY.AreaInterchange` loss terms from the attached `InterconnectorLossModel`, added on top of
# PSI's own lossless `-flow`/`+flow` balance terms (inherited from `AbstractBranchFormulation`).

"""
    NEMInterconnectorLoss

Device formulation for `PSY.AreaInterchange` that apportions the attached
[`InterconnectorLossModel`](@ref)'s segment losses between its two areas. Supports
`PSI.AreaBalancePowerModel` only, matching NEMDE's regional balance; other network models,
missing or ambiguous loss models and concave curves throw `ArgumentError`. The demand term of each
interval's loss factor is read from the interchange's `"loss_demand_coefficient"` series
(`set_loss_demand_coefficients!`) as a [`LossDemandCoefficientParameter`](@ref), so the formulation
also runs in recurrent simulations.

# Notes
Loss follows the breakpoint interpolation at every price sign: segments fill contiguously from
the first breakpoint, enforced by binary fill indicators when an interconnector has more than one
segment. The breakpoint range also bounds flow, with a warning when it is narrower than the
device's static flow limits.
"""
struct NEMInterconnectorLoss <: PSI.AbstractBranchFormulation end


"An interconnector's total loss at one timestep, in MW per-unit of base power."
struct InterconnectorLossVariable <: PSI.VariableType end


"""
One loss-curve segment's flow allocation for one interconnector at one timestep, in MW per-unit.
Indexed `(interconnector name, segment label, t)`; the segment axis is sized to the largest
interconnector's segment count, and a smaller interconnector's unused cells are fixed to `0.0`.
"""
struct InterconnectorLossSegmentVariable <: PSI.VariableType end


"`flow[ic,t] == first_breakpoint + sum(segment flows)`, both per-unit."
struct InterconnectorFlowSegmentConstraint <: PSI.ConstraintType end


"""
`loss[ic,t] == losses at the first breakpoint + sum(segment slope * segment flow) + k[t] * flow[ic,t]`,
per-unit, with segment slopes and first-breakpoint losses at zero demand and `k[t]` the
[`LossDemandCoefficientParameter`](@ref).
"""
struct InterconnectorLossDefinitionConstraint <: PSI.ConstraintType end


"""
Binary: segment `s` of an interconnector's loss curve is completely filled at one timestep. Indexed
`(interconnector name, segment label, t)`, with labels `1:(max segments - 1)`; cells beyond an
interconnector's own `segments - 1` appear in no constraint.
"""
struct InterconnectorLossSegmentFullVariable <: PSI.VariableType end


"""
Contiguous segment fill: segment `s + 1` may carry flow only when segment `s` is full
(`meta = "ub"`), and segment `s` is full when its fill indicator is on (`meta = "lb"`).
"""
struct InterconnectorLossSegmentOrderConstraint <: PSI.ConstraintType end


"""
    LossDemandCoefficientParameter

Coefficient of an interconnector's flow in its [`InterconnectorLossDefinitionConstraint`](@ref) at
each interval: the demand term `Σ_r demand_coefficients[r] × demand[r]` of its loss factor, read
from the `"loss_demand_coefficient"` series that `set_loss_demand_coefficients!` attaches.
"""
struct LossDemandCoefficientParameter <: PSI.ConstraintCoefficientParameter end
