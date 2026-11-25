# 0031 Interconnector loss segments fill contiguously

## Status

Accepted. Extends [0022](0022-interconnector-loss-formulation.md).

## What

- `NEMInterconnectorLoss` adds a binary `InterconnectorLossSegmentFullVariable` per segment boundary, so segments fill in order from the first breakpoint and the loss at a flow is the chord value for any price sign.
- An interconnector with one segment adds no binaries; a system of only single-segment interconnectors stays an LP.

## How

- Per boundary `s`: `segment[s + 1] <= width[s + 1] * z[s]` and `segment[s] >= width[s] * z[s]`, rows `InterconnectorLossConstraint` with metas `segment_order|ub` and `segment_order|lb`.
- Indicator cells beyond an interconnector's own segment count are unused and left to presolve, because PSI's dual pass reads one variable kind per container.
- PSI fixes the integers at their solved values and re-solves the LP for duals, which is how regional prices are read.
- `read_interconnector_loss_gaps` reports solved loss against the chord at the solved flow (zero gap when the fill is contiguous).
- A narrower `LOSSMODEL` breakpoint range than `flow_limits` still bounds flow and warns once at construction.

## Why

- With a non-positive weighted price (`share * price_from + (1 - share) * price_to`) the LP fills a steep segment while a cheaper one is idle and burns energy. The 10-interval baseline showed NSW1-QLD1 loss 875 MW against 1 MW published.
- An LP-only epigraph is exact only when loss is costly; bounding loss above for negative prices is non-convex, so any exact form needs integrality. Binaries were chosen over SOS2 because PSI already handles them. The semantics equal nempy's two-adjacent-points SOS2 weights.
- Run solves use a tight MIP gap (rel `1e-9`, abs `1e-10`, `NEMDE_HIGHS_OPTIONS`) because the objective is 1e6 to 1e8 once violation slacks are active.

## Departure from nempy and NEMDE

- With every indicator fixed in the dual LP, one side of a breakpoint is blocked. When the optimal flow sits exactly on a breakpoint the dual range is one-sided, and regional prices can violate the loss relationship. nempy keeps the nearest three breakpoint weights free in its pricing LP (`markets.py`); this package does not, and nothing shows NEMDE prices at a fixed dispatch point.
- The fix needs a hook in the pinned PSI fork's dual pass to leave the indicators adjacent to the solved flow free. Deferred.

## Sources

- AEMO Marginal Loss Factors FY2026-27, section 4, pp. 64-70; Electricity Data Model Report, `LOSSMODEL`, `LOSSFACTORMODEL`. No source documents NEMDE's internal linearisation.
