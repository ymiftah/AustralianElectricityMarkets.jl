# 0024 FCAS terms in generic constraints and dual-to-price mapping

## Status

Accepted. The dual-to-price reader is now `read_fcas_prices`.

## What

- `GenericConstraint`s carry FCAS terms (`SPDCONNECTIONPOINTCONSTRAINT` / `SPDREGIONCONSTRAINT` rows with an FCAS `BIDTYPE`), and AEMO's `DISPATCH_FCAS_REQ` prices are the marginal values of the constraints tagged by `FCASRequirement`.
- A term's variable is the unit's `FCASCapacityVariable` for a contingency service, or its `FCASUnitRegulationTarget` for a regulation service: the unit's single net target, which sums both sides for a bidirectional unit (AEMO *FCAS Model in NEMDE* section 2.4). A `RegionTerm` sums this over the region's devices, matching "FCAS Requirement Region (Service)" in AEMO *Constraint Formulation Guidelines* sections 5.3 and 5.4 (regulation on the LHS of the 5 minute requirement).
- A missing enablement is zero: a service absent from `sys`, unavailable or with no available devices, or a device with no variable in it, contributes nothing, as an unbid service is enabled for none of it in NEMDE. Absent services warn once per constraint.

## How

- The service name is `fcas_service_name`, `"<REGIONID>_<BIDTYPE>"`, with `REGIONID` from the device's own bus area, never from the term, so a bare DUID never borrows another term's region (shared with `add_fcas_services!`).
- A service with available devices but no `FCASMarket` model in the template throws at build; the pre-flight check reports it first as `:unmodeled_fcas_service`.
- No build-order handling is needed: `FCASMarket` makes its variables and `FCASUnitRegulationTarget` in `ArgumentConstructStage` and `LinearFactorLimit` adds terms in `ModelConstructStage` ([0015](0015-service-construct-stage-ordering.md)).
- `read_fcas_prices(results, sys; resolution)` sums the `NEMConstraintLimit` duals of constraints whose `fcas_requirements` name a `(region, service)` pair, divided by `base_power` and the interval length in hours (PSI duals are per interval of cost, so the length is needed as well as base power). Columns follow the published FCAS prices with `ROP`, the sum of `MARGINALVALUE`. A constraint with requirements but no recorded dual is warned about and left out.
- Duals keep the solver's sign (change in cost per unit RHS increase): a binding `>=` row is non-negative, a `<=` row non-positive.

## Departures from AEMO / not covered

- Duals are not capped at the Market Price Cap, so a violated requirement shows the violation-penalty-driven value set by the elastic generic-constraint slack ([0021](0021-elastic-generic-constraints.md)), not `RRP`.
- AEMO defines the marginal value the same way (constraint FAQ 3.15) but its references do not state the sign it publishes for `<=` rows; unverified, and FCAS requirements are `>=` rows.
