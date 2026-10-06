# 0030. Elastic unit ramp rows

## Status

Accepted

## Context

The two failed validation intervals (2026-06-13T04:15 and 2026-06-29T11:55) are infeasible on one
hard `PSI.RampConstraint` up row: HUMENSW, an offline hydro unit with `INITIALMW` -0.395 MW and
`RAMPUPRATE` 0, gives `x <= INITIALMW + RAMPUPRATE * dt < 0` against the bound `x >= 0`. NEMDE does
not fail here: the Unit Ramp Rate constraint carries `DeficitRampRate`/`SurplusRampRate`
variables.

AEMO *Schedule of Constraint Violation Penalty Factors* v8.0 (nem-expert
`constraint-violation-penalty-factors/03-items-01-11.md`), item 3 "Unit Ramp Rate constraint":
current CVP factor 1155 (old 440). Ranking: below Non-Conformance, above Energy Inflexible Offer
and Interconnector Capacity Limit.

## Decision

- `UnitRampUpSlack`/`UnitRampDownSlack`, one non-negative variable per `(device, t)`, enter the up
  and down rows of the `AbstractNEMDispatch` `PSI.RampConstraint` (`power - base - slack <= rate *
  minutes`, `base - power - slack <= rate * minutes`).
- Priced at `UNIT_RAMP_CVP_FACTOR` (1155) times the Market Price Cap, in `$/MW` per interval
  (`base_power * interval_cost_coefficient(1155 * MPC, resolution)`), the same scaling as the
  area-balance and FCAS slacks. The MPC comes from `_container_market_price_cap`, so the settings
  `"market_price_cap"` override applies.
- Always elastic, not gated on `use_slacks`: NEMDE's ramp row is always soft, and the device
  model has no slack switch of its own. The variable bounds (availability, minimum, band
  capacity) stay hard; only the ramp side relaxes, so an envelope that conflicts with the bounds
  is violated on the ramp row.
- Storage (`nem_dispatch_storage.jl`) ramp rows are not changed here; they and the other hard
  rows are the remainder of gap G10.

## Consequences

- The model is feasible whenever the bounds are, and the slack is zero whenever the hard row was
  satisfiable. At 1155 x MPC the slack is priced above every offer and above the 150 x MPC
  balance and 155 x MPC FCAS ramping slacks, so it is used only when no other relaxation exists.
- Surplus and deficit slacks are reported per direction, not as one signed pair.
