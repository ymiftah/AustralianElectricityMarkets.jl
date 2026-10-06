# 0032. Scheduled loads and unresolved generic-constraint terms

## Status

Accepted

## Context

A first 10-interval replication found two input gaps. 153 of 1422 invoked constraint versions
were skipped whole because one term named a DUID absent from the `System`, 140 of those terms
on scheduled loads (pumps). Separately `TOTALDEMAND` is "demand (less loads)" in
`DISPATCHREGIONSUM`, so dispatched scheduled load was missing from the balance.

## Decision: unresolved terms (G5)

- `add_nem_constraints!` drops a term whose DUID, region or interconnector is absent from the
  `System` and builds the constraint from the rest (`unresolved_terms = :drop`, the default). The
  dropped keys are recorded in the constraint's `ext["dropped_terms"]`. A constraint with no
  resolvable term at all is skipped with the reason of its first unresolved term.
- Basis: nempy builds constraint LHS rows with an inner merge of constraint terms on unit
  variables (`solver_interface.py`, `create_unit_level_generic_constraint_lhs`), so a term with no
  variable contributes nothing and the constraint stays. A unit that is in the `System` but
  unavailable already contributes zero. A unit unknown to us is different in cause (an input gap,
  not an offline unit), which is why the keys are recorded rather than silently ignored.
- Departure from AEMO: NEMDE's case contains every registered unit, so a constraint is never
  missing a term there. Dropping is an approximation that is exact only when the unit's dispatch is
  zero.

## Decision: scheduled loads (G4)

- **Which units.** `DUDETAILSUMMARY.DISPATCHTYPE = LOAD` with `SCHEDULE_TYPE = SCHEDULED`
  (60 in the June 2026 cache; wholesale demand response units are included). They were absent
  because `read_units` inner-joined `GENUNITS`, which has no row for most loads, and
  deduplicated `DUALLOC` per `GENSETID`, which dropped `OSB-AG` and `PTSTAN1` in favour of the legacy
  `OSB01`/`STANV1` rows. Non-scheduled loads, `DG_*` demand-response aggregates (no fuel source)
  and non-scheduled generators are still not in the `System`.
- **Component.** `InterruptiblePowerLoad` (a `ControllableLoad`) on `<REGION>_GEN_BUS`, with a
  decremental `MarketBidCost` built from the `LOAD` direction of `BIDPEROFFER_D`/`BIDDAYOFFER_D`,
  band order reversed as for a battery's load side. A load with no bid is made unavailable.
- **Formulation.** The load reuses the `AbstractNEMDispatch` `ActivePowerVariable`, bounded by
  `AVAILABILITY` (`DISPATCHLOAD.AVAILABILITY` is the load `MAXAVAIL`), ramped against `INITIALMW`
  (consumed MW, positive) with the same ramp rates, and priced on the decremental offer with the
  same objective sign as a battery's charge. Only its balance multiplier is -1.
- **Demand.** `TOTALDEMAND` is "demand (less loads)" and `DISPATCHABLELOAD` is "added to total
  demand to get inherent region demand" (MMS Data Model, `DISPATCHREGIONSUM`). The area balance
  therefore stays at `TOTALDEMAND` and the load is a withdrawal, so generation clears at demand plus
  scheduled load, as for a battery's charge. The load is not a `PowerLoad`, so the demand series
  and the interconnector loss demand are unchanged.
- **Constraint terms.** Generators and loads both enter a constraint LHS as a positive MW value
  (Constraint Implementation Guidelines 2.2); the constraint's own factor carries the sign
  (3.2.2, "the generator's factor multiplied by -1"). A load term therefore uses the consumed-MW
  variable with multiplier +1. A `RegionTerm` still aggregates only generators and storage.
- **Not modelled.** Load FCAS offers (G8). A load without FCAS bids is simply not a contributor.
  Ramp floors above availability are checked as for generators.
