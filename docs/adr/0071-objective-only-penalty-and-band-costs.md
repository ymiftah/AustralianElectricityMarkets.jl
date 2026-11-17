# 0071 Penalty and band costs stay objective-only

## Status

Accepted

## What

- Violation-penalty slacks (device rows, interconnector flow, area balance, FCAS, generic constraints) and FCAS and MNSP offer bands are priced by AEMSim into the objective only.
- `ProductionCostExpression` holds energy offer costs only and does not sum to the objective.
- Penalty costs are read from the `constraint_violations` table of the NEMDE results.

## Why

- Device penalty terms in a per-device expression would need their own step-update bookkeeping.
- FCAS, MNSP, generic-constraint and area-balance costs have no per-device expression to join, so the gap would only partly close.
