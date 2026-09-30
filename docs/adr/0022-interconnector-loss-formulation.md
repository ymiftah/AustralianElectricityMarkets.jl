# 0022. Interconnector losses as a convex segment accumulation on `AreaInterchange`

## Status

Accepted

## Context

`NEMInterconnectorLoss` (`AustralianElectricityMarketsSimulations/src/devices/interconnector_losses.jl`)
puts NEMDE's interconnector loss curve into the regional power balance. NEMDE's own formulation
(AEMO Electricity Data Model Report, `LOSSMODEL`/`LOSSFACTORMODEL`/`INTERCONNECTORCONSTRAINT`)
models loss as a quadratic in flow, linearised on `LOSSMODEL`'s own `MWBREAKPOINT` segments, and
splits the result between the two connected regions by `INTERCONNECTORCONSTRAINT.FROMREGIONLOSSSHARE`
("loss share attributable to from region"):

```text
generation_from - flow - share * loss       = demand_from
generation_to   + flow - (1 - share) * loss = demand_to
```

This matches `nempy`'s `markets.py::set_interconnector_losses` docstring exactly (same two
equations, same sign convention), confirming the regional-balance sign and the `share`/`1-share`
split against both AEMO's own data model and the open-source reference implementation.

## Decision

### Segment accumulation, not `nempy`'s SOS2 weights

Both this package and `nempy` linearise the quadratic loss curve on its breakpoints. `nempy`
(`spot_market_backend/interconnectors.py::link_inter_loss_to_interpolation_weights`) represents a
point on the curve as a convex combination of **interpolation weight** variables at each
breakpoint, summing to 1, with an SOS2 constraint restricting the solver to at most two *adjacent*
nonzero weights. This package instead gives each segment its own bounded flow-allocation variable
(`InterconnectorLossSegmentVariable`, `[0, segment width]`) and pins `flow` and `loss` to their sums
by equality (`InterconnectorFlowSegmentConstraint`/`InterconnectorLossDefinitionConstraint`) - no
SOS2, no binary variables.

For a convex loss curve (ascending chord slopes, checked once per interconnector by
`_validate_convex_segments`) and a cost-minimising LP where **increasing loss increases the
objective** (more loss means more generation must be dispatched somewhere, at positive marginal
cost), segment accumulation reproduces the same values as `nempy`'s SOS2 weights: the LP always
fills the lowest-slope (cheapest) segments first, which is exactly the chord value at any flow.
`LOSSMODEL` (AEMO Electricity Data Model Report) documents only the segment breakpoints
(`MWBREAKPOINT`) and the quadratic loss-factor form; none of the AEMO sources checked for this ADR
(the Data Model Report, Marginal Loss Factors FY2026-27, Treatment of Loss Factors) document
NEMDE's internal LP encoding of those segments, so no claim is made here about which of the two
encodings (this package's plain accumulation or `nempy`'s SOS2) is closer to NEMDE's own solver
internals. Plain accumulation is chosen for its simplicity (no SOS2/binary support needed from the
pinned PSI fork), at the cost documented below.

### Known gap: no hard floor against "over-dissipation" under a negative shadow price

Segment accumulation only reproduces the true convex-curve value **because** cost minimisation
prefers less loss. `InterconnectorFlowSegmentConstraint` is an equality on the *total* segment sum,
not on each segment individually, so for a fixed flow there is more than one way to split the
total across segments (e.g. filling segment 3 partially while leaving segment 1's cheaper capacity
unused) - the LP relies entirely on the objective's incentive to prefer the low-slope allocation,
not on a structural (SOS2 or big-M) guarantee that segments fill contiguously from the bottom.

If the marginal cost of supplying the loss is ever *negative* (a region with a negative dispatch
price, e.g. surplus renewable generation that is cheaper to dissipate through the interconnector
than to curtail), minimising the objective means **maximising** loss instead, and nothing in this
formulation prevents the LP from filling a higher-slope segment while leaving a lower-slope
segment's capacity idle for the same total flow - reporting a loss strictly above the true
convex-curve value at that flow ("over-dissipation"). `nempy`'s SOS2 constraint is specifically
what rules this out: at most two *adjacent* breakpoints can be active, which forces a canonical,
contiguous representation regardless of which direction the objective wants to push loss.

This is not fixed here: it is recorded as a known limitation of this package's own encoding choice
(not shown to be shared with, or a departure from, NEMDE's own undocumented internal LP - see
above). Fixing it (SOS2, or an explicit contiguous-fill ordering constraint) is Phase 3 scope, to
be revisited if a real dispatch interval is found where the solved flow's segment split does not
match the direct curve evaluation ([`interconnector_losses`](@ref)) at that flow.

The real-data check added alongside this ADR (`test/real_data/runtests.jl`) evaluates
[`interconnector_losses`](@ref) directly at each interconnector's published `MWFLOW` against
published `MWLOSSES` - a pure function check of the loss *curve*'s fidelity, independent of the LP.
It does not exercise the segment-ordering LP degeneracy above, since no LP is solved for that
comparison. A second check does solve `NEMInterconnectorLoss` (2026-06-04 00:00-01:00) and compares
its own `InterconnectorLossVariable` at the solved flow against the curve evaluated at that same
flow - the actual over-dissipation test.

**Real-data evidence (2026-06-04 00:00, first interval).** Regional price signs at `t1`: NSW1,
QLD1, SA1, TAS1, VIC1 positive; **SNOWY1 negative** - a genuine negative-price region existed in
this interval, the precondition the over-dissipation gap needs to be possible at all. The LP-vs-curve
gap at the solved flow was near zero for the three MNSP interconnectors (`N-Q-MNSP1`: 0.0 MW,
`T-V-MNSP1`: 0.002 MW, `V-S-MNSP1`: 0.0 MW) and small for `V-SA` (-3.5 MW), but large for the two
AC regulated interconnectors: `NSW1-QLD1` +951.9 MW and `VIC1-NSW1` -1140.9 MW. These two are far
larger than a plausible physical loss and are not confirmed as the over-dissipation phenomenon
this ADR describes - the more likely explanation, not yet investigated, is a region-name mismatch
between the attached `InterconnectorLossModel`'s `demand_coefficients` keys and this `System`'s six
`Area`s (`SNOWY1` split out from `NSW1`/`VIC1` in the 2026-27 network), which would silently zero
that region's demand contribution to the linear coefficient rather than error (see
[`loss_factor`](@ref)'s stated behaviour for a missing region). This is left as a flagged, unresolved
finding for a follow-up PR: confirm or rule out the region-mismatch hypothesis before treating the
two large gaps as evidence of genuine over-dissipation.

## Consequences

- `NEMInterconnectorLoss` never queries DuckDB; it reads the `InterconnectorLossModel`
  `PSY.SupplementalAttribute` `attach_interconnector_losses!` (root package) already stamped on
  each `AreaInterchange`, already per-unit of the `System`'s base power. No MW/pu conversion
  happens inside the formulation.
- A non-convex (`loss_flow_coefficient < 0` in a way that makes chord slopes descend) loss model
  throws at construction rather than silently mis-ordering segments.
- The over-dissipation gap above is untested and unresolved; a future PR that observes it in real
  data should either add an explicit contiguous-fill constraint or adopt `nempy`'s SOS2 encoding.
