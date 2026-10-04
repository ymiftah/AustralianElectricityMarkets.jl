# 0023. Elastic FCAS joint rows, and the area-balance slack at its own CVP rate

## Status

Accepted

## Context

`FCASJointCapacityConstraint` (AEMO `xxUpperDeficit`/`xxLowerSurplus`, EnablementMin/Max) and
`FCASJointRampingConstraint` (AEMO `R5REJointRampDeficit`/`L5REJointRampDeficit`, *FCAS Model in
NEMDE* section 6.1) were hard rows, so a unit whose published dispatch breaches its trapezium or
its AGC ramp made the LP infeasible. NEMDE gives both rows deficit/surplus terms priced at CVP
factors (ADR 0021 covers `GenericConstraint`; this ADR covers the FCAS rows).

AEMO's *Schedule of Constraint Violation Penalty Factors* v8.0 (nem-expert
`constraint-violation-penalty-factors/`): item 20 (FCAS Joint Ramping) factor 155, item 24 (FCAS
EnablementMin/Max) factor 70, items 22 and 23 (regional demand-supply balance, `DeficitGen`/
`SurplusGen`) factor 150. The resulting order, ramping 155 > balance 150 > enablement 70, is the
priority order AEMO documents (item 24: enablement limits "should be untrapped (violated) before
violating Regional Demand Supply Balance").

nempy (`elastic_constraints.py`) builds deficit variables for its generic constraints and its
regional balance; it has no joint-ramping row and its FCAS enablement rows are hard, so there is no
nempy counterpart to this change for the FCAS rows.

## Decision

- `FCASJointCapacitySlack`/`FCASJointRampingSlack` variables, built when the `FCASMarket`
  `PSI.ServiceModel` has `use_slacks = true`, one per `(unit, t)` and row. The row's sense fixes
  the slack's sign (`<=` rows subtract it, `>=` rows add it), so a single non-negative variable
  per row suffices; there is no up/down pair as for an `EQ` `GenericConstraint`. Capacity slacks
  merge into `FCASJointCapacityLHS`; the ramping slack enters its row directly.
- Priced at `cvp_factor x Market Price Cap x base_power`, in `$/MW` per dispatch interval, with the
  Market Price Cap resolved by ADR 0021's `_market_price_cap` (financial-year table or the
  `"market_price_cap"` attribute). Factors: `FCAS_CAPACITY_CVP_FACTOR = 70`,
  `FCAS_RAMPING_CVP_FACTOR = 155`.
- PSI's `AreaBalancePowerModel` slack (`SystemBalanceSlackUp`/`Down`) is repriced at
  `AREA_BALANCE_CVP_FACTOR = 150` x Market Price Cap by a more specific
  `PSI.objective_function!` method for `NetworkModel{AreaBalancePowerModel}` in `psi_compat.jl`.
  This closes the gap ADR 0021 lists: a Secure Network Limit Thermal `GenericConstraint` (factor
  30-35) now prices below the area balance, as AEMO ranks them.
- `MARKET_PRICE_CAP_BY_FINANCIAL_YEAR` gains FY2024-25 ($17,500/MWh, AEMC's 2024-25 schedule) so
  the mock-data fixtures dated January 2025 are priced.

## Departures from AEMO

- Rows that NEMDE does not build (placeholder `0 <= 1` rows for disabled intervals) still receive
  slack variables; they cost nothing and stay at zero.
- Regional balance: AEMO has separate `DeficitGen`/`SurplusGen` variables, both factor 150; PSI's
  up/down pair maps to them one-to-one.
- A `NetworkModel{AreaBalancePowerModel}` interval in a financial year absent from the table keeps
  PSI's `BALANCE_SLACK_COST`, rather than throwing as `_financial_year_mpc` does, because PSI's
  own test systems and non-NEM-era replays build area-balance models too. The cost is a silent
  price in those years.
- Not made elastic here: the `FCASBDURampingConstraint` (item 21, factor 155) and the FCAS
  MaxAvail rows (item 19, factor 155); both stay hard.
- FY2024-25's $17,500 is not in the nem-expert reliability-settings reference (it starts at
  FY2025-26); it is taken from AEMC's published 2024-25 schedule.

## Consequences

- `use_slacks = false` (PSI's default) leaves every FCAS row exactly as before.
- Every `AreaBalancePowerModel` network with `use_slacks = true` changes objective value where the
  slack is nonzero: the rate is now `150 x MPC` per MWh (about $2.6M at FY2024-25) rather than
  PSI's flat `BALANCE_SLACK_COST` per per-unit.
- The FCAS requirement terms linking generic constraints to regional FCAS prices (Phase 2.6) are
  unaffected.
