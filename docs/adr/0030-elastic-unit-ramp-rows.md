# 0030 Elastic unit ramp rows

## Status

Accepted. Extended to storage and the other families by [0037](0037-elastic-rows-remaining-families.md), and always-on by [0068](0068-device-rows-always-elastic.md).

## What

- The `PSI.RampConstraint` up and down rows of `AbstractNEMDispatch` devices are soft, as NEMDE's Unit Ramp Rate constraint carries `DeficitRampRate`/`SurplusRampRate`.
- Priced at `UNIT_RAMP_CVP_FACTOR` = 1155 times the Market Price Cap (AEMO *Schedule of Constraint Violation Penalty Factors* v8.0, item 3, "Unit Ramp Rate constraint"; old factor 440). It ranks below Non-Conformance and above Energy Inflexible Offer and Interconnector Capacity Limit.

## How

- `_add_nem_ramp_constraints!` adds a `NEMUnitSlack` per `(device, t)` of variant `unit_ramp|up` / `unit_ramp|down`: `power - base - slack_up <= rate * minutes` and `base - power - slack_dn <= rate * minutes`.
- Priced through `_add_cvp_slack!` at `base_power * interval_cost_coefficient(1155, resolution) * mpc`, `mpc` from `_container_market_price_cap` (so the settings `"market_price_cap"` override applies).
- Always built, not gated on `use_slacks`. Variable bounds (availability, minimum, band capacity) stay hard; only the ramp side relaxes.
- Violations are read with `read_constraint_violations` (family `unit_ramp`).

## Why

- A unit with `INITIALMW` below zero (an offline unit's auxiliary load) and a zero ramp-up rate gave `x <= INITIALMW + 0 < 0` against `x >= 0`: a hard row made two June 2026 intervals infeasible (HiGHS conflict: variable bounds plus the `RampConstraint` up row).
- At 1155 x cap the slack is priced above every offer and above the 150 balance and 155 FCAS slacks, so it is used only when nothing else can relax.
