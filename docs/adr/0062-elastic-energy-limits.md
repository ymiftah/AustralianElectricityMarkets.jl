# 0062 Elastic energy availability and UIGF limits

## Status

Accepted. Extends [0037](0037-elastic-rows-remaining-families.md); always on per [0068](0068-device-rows-always-elastic.md).

## What

- For non-storage `AbstractNEMDispatch` devices, in system-base per-unit, with `power >= 0`:
  - `power - max_avail_surplus <= bid MAXAVAIL`, priced at `ENERGY_MAX_AVAIL_CVP_FACTOR` (370);
  - semi-scheduled devices only: `power - uigf_surplus <= UIGF`, priced at `ENERGY_UIGF_CVP_FACTOR` (385).
- Cost is `base_power * interval_cost_coefficient(CVP, resolution) * Market Price Cap` per per-unit slack.
- There is no hard combined availability ceiling and no static-rating bound on the active-power variable.
- Sources: AEMO *Schedule of Constraint Violation Penalty Factors* v8.0, Table 1 items 12 (UIGF surplus, 385) and 14 (unit MaxAvail, 370); *Electricity Data Model Report* v5.7.0 BIDPEROFFER_D (per-direction MAXAVAIL) and DISPATCHLOAD (`AVAILABILITY`, `UIGF`).

## How

- The slacks are `NEMUnitSlack` variants `energy_limit|max_avail` and `energy_limit|uigf`; the limits are `EnergyLimitTimeSeriesParameter` (meta `max_avail`, `uigf`) updated each step; violations report under family `energy_limit`.
- AEM writes the separate MAXAVAIL and UIGF series. `check_dispatch_envelope` requires them complete, finite and non-negative, and missing inputs never select another formulation. A zero semi-scheduled forecast is a binding value.

## Why

- `DISPATCHLOAD.AVAILABILITY` equals UIGF for a semi-scheduled unit, while bid MAXAVAIL can be larger. With a hard availability bound, an invoked non-conformance constraint (CVP 1160) could not pull a unit to its `INITIALMW` above UIGF, though NEMDE does and pays the 385 penalty.
- Violation costs sum across rows, so conflicts between limits are resolved by total penalty, not by lexicographic choice.
