# 0068 NEM device and interconnector rows are always elastic

## Status

Accepted. Extends [0030](0030-elastic-unit-ramp-rows.md) and [0037](0037-elastic-rows-remaining-families.md).

## What

- The unit rows of `AbstractNEMDispatch` devices (ramp, energy limits, energy offer totals, fixed loading) and the interconnector flow rows always carry slacks, whatever `use_slacks` is on the `DeviceModel`.
- `use_slacks` stays meaningful for the services (`FCASMarket`, generic constraints), where a non-NEMDE study may want hard rows.

## Why

- NEMDE prices every violation of these rows at its Constraint Violation Penalty (AEMO *Schedule of Constraint Violation Penalty Factors* v8.0), so a hard row makes an interval infeasible where NEMDE clears it with a priced violation.
- Templates need no `use_slacks = true` on device models to stay NEMDE-faithful, and results always contain the device slack variables that the violation reader uses.
