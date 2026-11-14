# `PSY.AreaInterchange` loss terms from the attached `InterconnectorLossModel`, added on top of
# PSI's own lossless `-flow`/`+flow` balance terms (inherited from `AbstractBranchFormulation`).

"""
    NEMInterconnectorLoss

Device formulation for `PSY.AreaInterchange` that apportions the attached
[`InterconnectorLossModel`](@ref)'s segment losses between its two areas. Supports
`PSI.AreaBalancePowerModel` only, matching NEMDE's regional balance; other network models,
missing or ambiguous loss models and concave curves throw `ArgumentError`. The demand term of each
interval's loss factor is read from the interchange's `"loss_demand_coefficient"` series
(written by [`nem_system`](@ref)) as a [`LossDemandCoefficientParameter`](@ref), so the formulation
also runs in recurrent simulations.

# Notes
Loss follows the breakpoint interpolation at every price sign: segments fill contiguously from
the first breakpoint, enforced by binary fill indicators when an interconnector has more than one
segment. The breakpoint range also bounds flow, with a warning when it is narrower than the
device's static flow limits. Flow-limit rows always carry priced slacks; the device model's
`use_slacks` does not apply to them. Slack penalties and MNSP band costs are objective terms only,
not part of any PowerSimulations cost expression.
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


"""
    InterconnectorLossConstraint

Row over one interconnector, per-unit. The key meta names the row, and a composite meta continues after
its first `|`:

- `"flow_segment"`: `flow[ic,t] == first_breakpoint + sum(segment flows)`, indexed `(interconnector name, t)`.
- `"loss_definition"`: `loss[ic,t] == losses at the first breakpoint + sum(segment slope * segment flow) + k[t] * flow[ic,t]`,
  with segment slopes and first-breakpoint losses at zero demand and `k[t]` the
  [`LossDemandCoefficientParameter`](@ref). Indexed `(interconnector name, t)`.
- `"segment_order|ub"` and `"segment_order|lb"`: contiguous segment fill. Segment `s + 1` may carry flow only when
  segment `s` is full (`ub`), and segment `s` is full when its fill indicator is on (`lb`). Indexed
  `(interconnector name, segment label, t)`.
"""
struct InterconnectorLossConstraint <: PSI.ConstraintType end


"""
Binary: segment `s` of an interconnector's loss curve is completely filled at one timestep. Indexed
`(interconnector name, segment label, t)`, with labels `1:(max segments - 1)`; cells beyond an
interconnector's own `segments - 1` appear in no constraint.
"""
struct InterconnectorLossSegmentFullVariable <: PSI.VariableType end


"""
    LossDemandCoefficientParameter

Coefficient of an interconnector's flow in its `"loss_definition"` [`InterconnectorLossConstraint`](@ref) at
each interval: the demand term `Σ_r demand_coefficients[r] × demand[r]` of its loss factor, read
from the `"loss_demand_coefficient"` series that [`nem_system`](@ref) writes.
"""
struct LossDemandCoefficientParameter <: PSI.ConstraintCoefficientParameter end
