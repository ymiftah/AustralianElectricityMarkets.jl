# 0022 Interconnector losses as a convex segment accumulation on `AreaInterchange`

## Status

Accepted. Contiguous segment fill is [0031](0031-interconnector-loss-contiguous-segment-fill.md) (it replaces the over-dissipation gap this ADR first recorded); loss demand is [0027](0027-loss-equation-regional-demand.md); input assumptions are [0091](0091-interconnector-loss-input-assumptions.md).

## What

- `NEMInterconnectorLoss` puts NEMDE's interconnector loss into the regional balance. NEMDE models loss as a quadratic in flow, linearised on `LOSSMODEL`'s `MWBREAKPOINT` segments, and splits it by `INTERCONNECTORCONSTRAINT.FROMREGIONLOSSSHARE` (AEMO Electricity Data Model Report):

```text
generation_from - flow - share * loss       = demand_from
generation_to   + flow - (1 - share) * loss = demand_to
```

- This matches nempy `set_interconnector_losses`, including sign convention and the `share` / `1 - share` split.
- AEMO's Marginal Loss Factors FY2026-27 report (section 4, pp. 64-70) defines the loss equations on the notional-link transfer; the data model report's `LOSSFACTORMODEL.DEMANDCOEFFICIENT` (v5.7.0, pp. 408-409) is the coefficient on regional demand.

## How

- No SOS2 and no nempy-style interpolation weights: each segment has a bounded flow variable `InterconnectorLossSegmentVariable` ([0, segment width]), with `flow == first_breakpoint + sum(segment flows)` and `loss == loss(first_breakpoint) + sum(slope x segment) + k[t] x flow`, `k[t]` being `LossDemandCoefficientParameter`. Rows are `InterconnectorLossConstraint` metas `flow_segment`, `loss_definition`, `segment_order|ub/lb` (the last from 0031).
- The formulation reads the `InterconnectorLossModel` supplemental attribute on each `AreaInterchange` (per-unit of system base) and never queries DuckDB. Demand enters through the `"loss_demand_coefficient"` series, so recurrent simulations work.
- `_validate_convex_segments` throws `ArgumentError` if chord slopes do not ascend, checked once per interconnector against empty demand (demand shifts every slope by the same constant, so only the sign of `loss_flow_coefficient` matters; zero is valid).
- The breakpoint range is an implicit flow limit, `[breakpoints[1], breakpoints[end]]`, on top of `flow_limits`; a narrower range warns once at construction.
- Only `PSI.AreaBalancePowerModel` is supported; any other network model throws `ArgumentError`. `read_interconnector_loss_gaps` compares solved loss with the chord at the solved flow and reports the weighted loss price `share x price_from + (1 - share) x price_to`.
- The flow-limit rows are re-implemented, not PSI's `FlowLimitConstraint` builder, which dispatches on the concrete `DeviceModel{AreaInterchange, StaticBranch}`.

## Why

- Plain accumulation needs no SOS2 or binary support from the pinned PSI fork. It is exact only when a unit of loss costs something (weighted price above zero); 0031 adds the binary ordering for the other cases. No AEMO document found describes NEMDE's internal LP encoding, so no claim is made about which encoding is closer to NEMDE's.
- NEMDE balances energy per region with interconnectors as notional links and network physics enters through generic constraints, so a PTDF network model is out of scope. `AreaPTDFPowerModel` was tried and removed: equating interchange flow to the sum of PTDF boundary-branch flows forces the loss share to zero (nodal injections sum to total loss and the reference bus absorbs it), so with `loss_constant = 1.05` every flow and loss solved to zero.
