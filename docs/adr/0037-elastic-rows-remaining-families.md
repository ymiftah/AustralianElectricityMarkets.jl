# 0037 Elastic rows for FCAS MaxAvail, BDU SCADA, storage ramp and interconnector flow

## Status

Accepted. Extends [0030](0030-elastic-unit-ramp-rows.md); device and interconnector rows are always on ([0068](0068-device-rows-always-elastic.md)); availability and UIGF are soft in [0062](0062-elastic-energy-limits.md) and storage availability in [0063](0063-elastic-storage-availability.md).

## What

- A hard row turns any conflicting input into an infeasible interval, where NEMDE relaxes it at its Constraint Violation Penalty (CVP) factor (AEMO *Schedule of Constraint Violation Penalty Factors* v8.0, Table 1).
- Rows made elastic here, each priced at `factor x Market Price Cap`:

| Item | Row | Factor | Slack |
| --- | --- | --- | --- |
| 3 | Storage unit ramp up and down | 1155 | `NEMUnitSlack` (`unit_ramp` variants) |
| 5 | Interconnector flow limit (FlowDeficit/FlowSurplus) | 1150 | `InterconnectorFlowSlack` (`surplus` upper, `deficit` lower) |
| 19 | FCAS MaxAvail | 155 | `FCASSlack` (`max_avail`) |
| 21 | BDU regulation FCAS SCADA ramping | 155 | `FCASSlack` (`bdu_ramping`) |

- The factors are `UNIT_RAMP_CVP_FACTOR`, `INTERCONNECTOR_FLOW_CVP_FACTOR`, `FCAS_MAXAVAIL_CVP_FACTOR` and `FCAS_BDU_RAMPING_CVP_FACTOR`.

## How

- Storage ramp rows use the same helper as generator rows ([0030](0030-elastic-unit-ramp-rows.md)).
- FCAS MaxAvail is `capacity - slack <= MaxAvail`, for single-sided and both-side (BDU) capacity variables. FCAS slacks are built only when the `FCASMarket` service model has `use_slacks = true`; otherwise MaxAvail is the variable's upper bound. A device disabled by the §5 enablement pre-conditions is still pinned to zero, since that is a precondition and not a row.
- Interconnector flow slacks are always built. The loss breakpoint range stays a hard bound: the Schedule has no penalty item for it.
- Violations are read with `read_constraint_violations`; `up` relaxes a `<=` row and `down` a `>=` row.

## Why

- The ordering must match AEMO: area balance (150) breaks before FCAS MaxAvail and ramping (155), then interconnector flow (1150), then unit ramp (1155).
- Flow-limit and storage-ramp slacks need a Market Price Cap for every interval, so a build dated before the cap table starts throws unless the `"market_price_cap"` setting supplies one.
- MNSP link availability (item 16, 365) is soft in [0076](0076-mnsp-operating-limits.md), below the flow limit (1150), matching the Schedule order.
- Objective coefficients span about 1e9 to 1e10 (1155 x $23,200 x system base against offers); the MIP gaps are in `NEMDE_HIGHS_OPTIONS`.
