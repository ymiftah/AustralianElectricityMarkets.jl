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

### Known gap: no hard floor against "over-dissipation"

Segment accumulation only reproduces the true convex-curve value **because** cost minimisation
prefers less loss. `InterconnectorFlowSegmentConstraint` is an equality on the *total* segment sum,
not on each segment individually, so for a fixed flow there is more than one way to split the
total across segments (e.g. filling segment 3 partially while leaving segment 1's cheaper capacity
unused) - the LP relies entirely on the objective's incentive to prefer the low-slope allocation,
not on a structural (SOS2 or big-M) guarantee that segments fill contiguously from the bottom.

The relevant sign is the **loss's weighted marginal price**, not either region's price alone: a
unit of loss costs `share * price_from + (1 - share) * price_to` (it is drawn from both regions in
those proportions). The LP has no incentive to over-dissipate, and the segment encoding is exact,
whenever this weighted price is `> 0`. At zero weighted price, loss allocation can be
indeterminate and need not reproduce the interpolation. When it is negative, minimising the objective means
maximising loss instead, and nothing here prevents the LP from filling a higher-slope segment while
leaving a lower-slope segment's capacity idle for the same total flow - reporting a loss strictly
above the true convex-curve value at that flow. `nempy` (`spot_market_backend/interconnectors.py`,
`markets.py:3040`'s `add_sos_type_2`) uses a genuine SOS2 constraint over interpolation weights,
which rules this out structurally: at most two *adjacent* breakpoints can be active, forcing a
canonical, contiguous representation regardless of which direction the objective wants to push
loss.

This is not fixed here. `LOSSMODEL` (AEMO Electricity Data Model Report) documents only the segment
breakpoints and the quadratic loss-factor form; none of the AEMO sources checked for this ADR (the
Data Model Report, Marginal Loss Factors FY2026-27, Treatment of Loss Factors) document NEMDE's
internal LP encoding of those segments, so no claim is made about which of the two encodings (this
package's plain accumulation or `nempy`'s SOS2) is closer to NEMDE's own solver internals. Plain
accumulation is kept for its simplicity (no SOS2/binary support needed from the pinned PSI fork).
Fixing the gap (SOS2, or an explicit contiguous-fill ordering constraint) is Phase 3 scope.
[`check_interconnector_loss_segments`](@ref) is a cheap post-solve diagnostic - it compares the
solved `InterconnectorLossVariable` against the interpolation between the two surrounding
breakpoints at the solved flow and `@warn`s on any interconnector whose gap exceeds a tolerance - used in the real-data suite
below and available to any caller solving `NEMInterconnectorLoss` on real data.

**Real-data evidence (2026-06-04 00:00-01:00, `~/.nemdb_cache`), after fixing two harness/formulation
bugs found while gathering this evidence** (both now fixed, see the commits in this ADR's PR): the
real-data demand lookup keyed a `Dict` by `DataFrames.GroupKey` and then looked it up by `DateTime`,
so every lookup missed and every demand term silently read as zero; and `_area_demand` re-applied a
load's own `scaling_factor_multiplier` on top of `PSY.get_time_series_values`, which already applies
it, giving 20x the true demand. Together these made the loss curve's linear coefficient for
`VIC1-NSW1` and `NSW1-QLD1` implausibly wrong, which is what the previous version of this ADR
mis-attributed to a "SNOWY1 region mismatch" (also wrong: `SNOWY1`/`V-SN` were retired in 2008, not
introduced in 2026-27 - see the `read_interconnectors` fix in this PR, which drops them from the
region set entirely rather than letting them appear as a phantom, meaningless area). With both bugs
fixed:

- Loss-curve fidelity (published `MWFLOW` -> [`interconnector_losses`](@ref) vs published
  `MWLOSSES`, `INTERVENTION = 0` only, `TOTALDEMAND` demand): across 78 observations, mean
  absolute error was 0.152 MW and maximum absolute error was 1.180 MW. Per-interconnector mean
  errors were N-Q-MNSP1 0.000, NSW1-QLD1 0.111, T-V-MNSP1 0.002, V-S-MNSP1 0.022, V-SA
  0.504, and VIC1-NSW1 0.275 MW.
- Over-dissipation gap ([`check_interconnector_loss_segments`](@ref), solved `NEMInterconnectorLoss`
  vs the breakpoint interpolation at the solved flow): all six interconnectors had zero gap to
  four decimal places, with no negative weighted-price intervals in the sampled hour. The
  real-data assertion passed for every positive weighted-price pair. Comparing against the
  quadratic directly would count ordinary chord approximation error as excess loss.
- Demand definition: this package uses `DISPATCHREGIONSUM.TOTALDEMAND`; `nempy`
  (`historical_inputs/mms_db/mms_tables.py`) instead builds regional demand from
  `INITIALSUPPLY + DEMANDFORECAST`. Both were compared against published losses over the same hour;
  `INITIALSUPPLY + DEMANDFORECAST` gave mean/max absolute errors of 1.405/11.676 MW, versus
  0.152/1.180 MW for `TOTALDEMAND`. The latter was more accurate overall for this sample, though
  V-SA's mean error was smaller with the alternative definition (0.381 versus 0.504 MW).
  The package retains `TOTALDEMAND`.

## Consequences

- `NEMInterconnectorLoss` never queries DuckDB; it reads the `InterconnectorLossModel`
  `PSY.SupplementalAttribute` `attach_interconnector_losses!` (root package) already stamped on
  each `AreaInterchange`, already per-unit of the `System`'s base power. No MW/pu conversion
  happens inside the formulation.
- A non-convex (`loss_flow_coefficient < 0` in a way that makes chord slopes descend) loss model
  throws at construction rather than silently mis-ordering segments; `loss_flow_coefficient == 0`
  (a straight-line curve) is valid and passes.
- The over-dissipation gap is untested (beyond the diagnostic above) and unresolved; a future PR
  that observes it in real data should either add an explicit contiguous-fill constraint or adopt
  `nempy`'s SOS2 encoding.
- Convexity is checked once per interconnector, against an empty demand: segment `i`'s chord slope
  is `linear(demand) + 0.5 * loss_flow_coefficient * (breakpoints[i] + breakpoints[i + 1])`, and
  `linear(demand)` is the same additive constant on every segment, so only the sign of
  `loss_flow_coefficient` decides whether the slopes ascend.
- The breakpoint range is an implicit flow limit: `flow == breakpoints[1] + sum(segment flows)`
  confines flow to `[breakpoints[1], breakpoints[end]]`, on top of (and possibly tighter than)
  the interconnector's own `flow_limits`. Real `LOSSMODEL` breakpoints span the operating range;
  a narrower model produces one summary warning at construction.
- The loss constraint set is a re-implementation rather than a reuse of PSI's `FlowLimitConstraint`
  builder, which dispatches on the concrete `DeviceModel{AreaInterchange, StaticBranch}` type.
- Not modelled: `nempy`'s MNSP transmission loss factors
  (`historical_inputs/historical_interconnectors.py::_format_mnsp_transmission_loss_factors`), a
  separate fixed loss applied to MNSP interconnectors on top of the interconnector's own dynamic
  loss model. This package's `InterconnectorLossModel` carries only the dynamic component.

## Review follow-up, 2026-10-01

The post-solve diagnostic reads `OptimizationProblemResults` in natural MW and compares the
solved loss to the chord between the surrounding breakpoints, rather than the quadratic value.
This removes an expected interpolation error that made the multi-segment toy test fail despite
its segment-order assertion passing. The toy test also checks a hand-derived chord formula,
independently of the diagnostic. On 2026-10-01, the interconnector-loss group passed 23 assertions,
the focused real-data loss checks passed seven, and the interconnector-reader checks passed five.

## Construction support, 2026-10-02

The formulation supports standalone `DecisionModel`s using `AreaBalancePowerModel` only, and
rejects every other network model with an `ArgumentError`. NEMDE balances energy per region with
interconnectors as notional links; network physics enters through generic constraint equations,
not a PTDF. AEMO's
[Marginal Loss Factors FY2026-27](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2026-27/marginal-loss-factors-for-the-2026-27-financial-year.pdf),
section 4, pp. 64-70, defines the loss equations in terms of the notional-link transfer.

`AreaPTDFPowerModel` was tried and removed. Equating each interchange flow to the signed sum of
its PTDF boundary-branch flows (PSI's `LineFlowBoundConstraint`) forces the loss share to zero:
losses enter only the area balances, so the nodal injections feeding the PTDF sum to the total
loss and the reference bus absorbs it. With `loss_constant = 1.05` on a three-area mesh every
interchange flow and loss solved to zero and the cheap area's generation was stranded; the same
model was correct only for a lossless curve. Supporting PTDF would need each area's loss share
injected as a nodal withdrawal, or the link made on sending-end and receiving-end flows. That is
outside NEMDE's regional model and is not planned.

Demand is snapshotted from available `PowerLoad`s at construction, with each forecast's
scaling factor applied once. This matches the availability selection of PSI's
`StaticPowerLoad` regional balance. AEMO's section 4.1, p. 64, explicitly makes the QNI
linear coefficient depend on NSW and Queensland demand; the
[Electricity Data Model Report](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/),
version 5.7.0, `LOSSFACTORMODEL`, pp. 408-409, defines `DEMANDCOEFFICIENT` as the coefficient
applied to regional demand in calculating the interconnector loss factor.

The loss-definition rows contain numeric demand-dependent coefficients. Recurrent solves
are rejected at argument construction, matching the existing `FCASMarket` restriction.
Callers must rebuild the `DecisionModel` after changing demand forecasts or load
availability. Rebuilding is the supported interval-refresh path; parameter and coefficient
update machinery for a reused `Simulation` is deferred. This is an explicit implementation
restriction rather than an assertion that NEMDE holds demand constant between intervals.
The existing choice of modeled regional demand and the negative weighted-price segment
ordering limitation remain unchanged.

The loss variable stays unbounded above. The nonpositive weighted-price case cannot be rejected
at build time because prices are an output of the solve, so `check_interconnector_loss_segments`
reports the resulting gaps after the fact.
