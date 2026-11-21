# 0085 Market Price Cap penalties fixed at build, one financial year per simulation

## Status

Accepted. Replaces per-step re-pricing of the penalties (removed ADRs 0065 and 0070).

## What

- Each Market Price Cap (MPC) penalty is a constant of the invariant objective: CVP factor times the cap times the interval length, per MW of slack. The cap is the one dated by the container's initial time, or the `market_price_cap` override of `DecisionModel{M}`.
- A run never crosses a financial year: `nem_system` refuses a `date_range` whose dispatch intervals span two financial years, and `dispatch_chunks` splits chunks at 00:05 on 1 July.
- The financial year of an interval ending at `t` is that of `t - 5 minutes`, so the interval ending 00:00 on 1 July belongs to the earlier year.
- Penalty factors are unchanged: AEMO *Schedule of Constraint Violation Penalty Factors* v8.0.

## How

- `_add_mpc_penalty!` adds the slack terms using `_container_market_price_cap`, which reads `ext["market_price_cap"]` (set at every build from the initial time, or the override) and falls back to `_financial_year_mpc`.
- Generic-constraint slack costs follow the same rule ([0103](0103-aggregated-generic-constraint-containers.md), [0101](0101-aem-writes-aemsim-reads.md)).

## Why

- A model is built once per chunk, so a single cap holds throughout and no per-step penalty parameter is needed. The earlier `MarketPriceCapPenaltyParameter` is gone.
