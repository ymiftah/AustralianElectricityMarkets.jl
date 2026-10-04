# 0024. FCAS terms in generic constraints and dual-to-price mapping

## Status

Accepted

## Context

`GenericConstraint`s on real data carry FCAS terms (`SPDCONNECTIONPOINTCONSTRAINT`/
`SPDREGIONCONSTRAINT` rows with an FCAS `BIDTYPE`), and AEMO's `DISPATCH_FCAS_REQ` prices come
from the marginal values of the constraints tagged by `FCASRequirement`.

## Decision

- **Build order.** No reordering is needed: `FCASMarket` creates its variables and the
  `FCASUnitRegulationTarget` expression in `ArgumentConstructStage`, and `LinearFactorLimit`
  adds terms in `ModelConstructStage` (ADR 0015), so every FCAS variable exists whatever order
  PSI iterates its service `Dict` in.
- **Service resolution.** A term names a device (or a region's devices, already attributed at
  ingestion). The service is `"<REGIONID>_<BIDTYPE>"` with `REGIONID` read from the device's own
  bus area, never from the term, so a bare DUID never borrows another term's region.
- **Variable.** Contingency services read `FCASCapacityVariable`; regulation services read
  `FCASUnitRegulationTarget` (the unit's single net regulation target, which sums both sides
  for a bidirectional unit; AEMO *FCAS Model in NEMDE* §6.4). A `RegionTerm` is the sum of this
  over the region's devices, matching "FCAS Requirement Region (Service)" in AEMO *Constraint
  Formulation Guidelines* §5.3 and §5.4 (regulation on the LHS of the 5 minute requirement).
- **Missing enablement is zero.** A service absent from `sys`, or a device with no variable in
  it, contributes nothing: a unit that did not bid a service is enabled for none of it, as in
  NEMDE. A service that exists but has no `FCASMarket` model in the template throws.
- **Prices.** `compute_fcas_prices` sums `NEMConstraintLimit` duals over the constraints whose
  `fcas_requirements` name a `(region, service)` pair, divided by `base_power` and the interval
  length in hours. Output columns match `read_fcas_prices`; the sum corresponds to `ROP`, not
  `RRP`. The master plan said "divided by base power"; the interval length is also needed
  because PSI duals are per interval of cost.
- **Pre-flight.** `filter_buildable_generic_constraints` treats an FCAS term as buildable when
  the template sets any `FCASMarket` model.

## Departures from AEMO / not covered

- A constraint's FCAS term is not made elastic here; FCAS rows keep hard bounds.
- Duals are not capped at the Market Price Cap, so a violated requirement shows the
  violation-penalty-driven value that the elastic generic-constraint slack sets, not `RRP`.
