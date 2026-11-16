# 0023 Elastic FCAS rows, and the area-balance slack at its own CVP rate

## Status

Accepted. The slack types are merged into `FCASSlack` by [0100](0100-one-key-type-per-family-and-role.md); MaxAvail and BDU SCADA rows were made elastic by [0037](0037-elastic-rows-remaining-families.md).

## What

- FCAS rows are soft when the `FCASMarket` `PSI.ServiceModel` has `use_slacks = true`, each priced at `cvp_factor x Market Price Cap` (AEMO *Schedule of Constraint Violation Penalty Factors* v8.0, Table 1):

| Row | AEMO variable | Item | Factor |
| --- | --- | --- | --- |
| Joint ramping (*FCAS Model in NEMDE* section 6.1) | `R5REJointRampDeficit`/`L5REJointRampDeficit` | 20 | `FCAS_RAMPING_CVP_FACTOR` = 155 |
| Joint capacity, EnablementMin/Max | `xxUpperDeficit`/`xxLowerSurplus` | 24 | `FCAS_CAPACITY_CVP_FACTOR` = 70 |
| Regional demand-supply balance | `DeficitGen`/`SurplusGen` | 22, 23 | `AREA_BALANCE_CVP_FACTOR` = 150 |

- Resulting order, ramping 155 > balance 150 > enablement 70, is AEMO's: item 24 says enablement limits "should be untrapped (violated) before violating Regional Demand Supply Balance".

## How

- One non-negative `FCASSlack` variable per `(unit, t)` and row (meta variants `joint_capacity`, `joint_ramping`). The row sense fixes its sign (`<=` rows subtract, `>=` rows add), so no up/down pair is needed.
- The slack enters the constraint row, so the stored `FCASJointCapacityLHS` expression stays AEMO's left-hand side.
- The area-balance slack is the `AreaBalancePowerModel` network model's `slack_cost` (`_area_balance_network_model`): `AREA_BALANCE_CVP_FACTOR x cap` per MW of one interval times base power, replacing PSI's flat cost. A secure-network-limit `GenericConstraint` (factor 30-35) therefore prices below the balance, as AEMO ranks them.
- The cap is the settings `"market_price_cap"` entry, else `MARKET_PRICE_CAP_BY_FINANCIAL_YEAR` ([0085](0085-build-time-market-price-cap.md)). A year absent from the table with no override throws, since falling back to PSI's flat cost would invert the CVP order.

## Departures from AEMO

- Placeholder `0 <= 1` rows for intervals NEMDE builds no row for still get slack variables; they cost nothing and stay zero. Skipping them would leave undefined container entries PSI reads on export.
- The regional balance maps PSI's up/down slack pair one-to-one onto `DeficitGen`/`SurplusGen` (both factor 150).
- FY2024-25's $17,500/MWh is taken from AEMC's 2024-25 schedule, not the nem-expert reliability-settings reference (which starts at FY2025-26).

## Why

- Hard FCAS rows make an interval infeasible whenever published dispatch breaches its trapezium or AGC ramp, where NEMDE relaxes at the CVP.
- nempy has no joint-ramping row and hard enablement rows, so there is no reference to copy.
