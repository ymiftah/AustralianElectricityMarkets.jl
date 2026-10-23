# 0068. NEM device and interconnector rows are always elastic

## Status

Accepted. Extends [0064](0064-elastic-energy-offer-totals.md).

## Context

PSI's `use_slacks` on a `DeviceModel` or `ServiceModel` decides whether a formulation adds slack
variables. Stock PSI creates device slacks only when it is `true` (for example the thermal ramp
slacks, `thermalgeneration_constructor.jl`). AEMSim honours `use_slacks` for its FCAS and generic
constraint services. Its NEM device and interconnector rows ignore it and always carry slacks:

- unit ramp up and down (`UnitRampUpSlack`, `UnitRampDownSlack`);
- energy `MAXAVAIL` and UIGF (`EnergyMaxAvail*Slack`, `EnergyUIGFSlack`);
- energy offer totals (`EnergyOffer*Slack`, `EnergyDecrementalOffer*Slack`);
- fixed loading (`EnergyFixedLoad*Slack`);
- interconnector flow limits (`InterconnectorFlowSurplusSlack`, `InterconnectorFlowDeficitSlack`).

A review against PSI's patterns flagged this as an inconsistency between AEMSim's device and
service halves.

## Decision

These rows stay elastic whatever `use_slacks` is. NEMDE prices every violation of them at its
Constraint Violation Penalty (AEMO, *Schedule of Constraint Violation Penalty Factors*, v8.0), so
a hard row would make a dispatch interval infeasible where NEMDE clears it with a priced violation.
`use_slacks` stays meaningful for the services, where a non-NEMDE study may want hard FCAS or
generic constraint rows.

The slacks of ramp and interconnector flow rows are created with their rows in the model stage,
as PSI creates its own service slacks (`services_models/reserves.jl`), since they and their prices
belong to the row they relax.

## Consequences

- A device model's `use_slacks` has no effect on NEM dispatch or `NEMInterconnectorLoss`.
- Templates do not need `use_slacks = true` on device models to stay NEMDE-faithful.
- Results always contain the device slack variables, which the replication violation report reads.
