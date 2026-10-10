# 0032. Scheduled loads and unresolved generic-constraint terms

## Status

Accepted

## Context

A first 10-interval replication found two input gaps. 153 of 1422 invoked constraint versions
were skipped whole because one term named a DUID absent from the `System`, 140 of those terms
on scheduled loads (pumps). Separately `TOTALDEMAND` is "demand (less loads)" in
`DISPATCHREGIONSUM`, so dispatched scheduled load was missing from the balance.

## Decision: unresolved terms (G5)

- `add_nem_constraints!` drops an unresolved *unit* term (a DUID absent from the `System`) and
  builds the constraint from the rest (`unresolved_terms = :drop`, the default). Each dropped term
  is recorded with its kind, key, `BIDTYPE` and factor in the constraint's `ext["dropped_terms"]`
  and in `get_dropped_terms(sys)`. An unresolved region or interconnector term still skips the
  constraint, because an unmodelled regional aggregate or flow is not zero. A constraint with no
  resolvable term is skipped. The skip reason is the kind of the first unresolved term.
- Basis: nempy builds constraint LHS rows with an inner merge of constraint terms on unit
  variables (`solver_interface.py`, `create_unit_level_generic_constraint_lhs`), so a term with no
  variable contributes nothing and the constraint stays. A unit in the `System` but unavailable
  already contributes zero.
- Departure from AEMO: NEMDE's case contains every registered unit, so a constraint is never
  missing a term there. Dropping is exact only when the unit's dispatch is zero. For a unit that is
  dispatched, the closest NEMDE-faithful treatment is to move `factor * TOTALCLEARED` of the dropped
  term to the right-hand side (Constraint Implementation Guidelines 3.2.1, non-modelled units move
  to the RHS). That is a follow-up: it needs the published `DISPATCHLOAD.TOTALCLEARED` of the
  dropped units, and the dropped-term record carries what it needs.
- Merge with the skipped-constraints table (`get_skipped_constraints`, PR #164): dropped terms live
  in a separate `ext` key and table so the two branches edit the same term loop only locally. After
  merging, `get_dropped_terms` rows can be appended to the skipped table with a `:term_dropped`
  status.
- Dropped non-scheduled load terms are mostly connection-point aliases (for example `VICSMLT`
  shares `VAPS`), because `read_constraint_terms` fans a connection point out to every DUID on it.
  That is a follow-up gap. Dropped FCAS terms on ancillary-service loads (`APD01`, `AS*`, `DRVIOT*`)
  push requirements onto other providers until load FCAS offers (G8) exist.

## Decision: scheduled loads (G4)

- **Which units.** `DUDETAILSUMMARY.DISPATCHTYPE = LOAD` with `SCHEDULE_TYPE = SCHEDULED`
  (60 in the June 2026 cache). They were absent because `read_units` inner-joined `GENUNITS`, which
  has no row for most loads, and
  deduplicated `DUALLOC` per `GENSETID`, which dropped `OSB-AG` and `PTSTAN1` in favour of the legacy
  `OSB01`/`STANV1` rows. A few loads (`PUMP2`, `SHPUMP`) do have a `GENUNITS` row, so
  `get_generators_dataframe` excludes `DISPATCHTYPE = LOAD`: otherwise the DUID would name both a
  generator and a load and `get_component(Device, ...)` would throw. Non-scheduled loads, `DG_*` demand-response aggregates (no fuel source)
  and non-scheduled generators are still not in the `System`.
- **Component.** `InterruptiblePowerLoad` (a `ControllableLoad`) on `<REGION>_GEN_BUS`, with a
  decremental `MarketBidCost` built from the `LOAD` direction of `BIDPEROFFER_D`/`BIDDAYOFFER_D`,
  band order reversed as for a battery's load side. A load with no bid is made unavailable, as is
  a wholesale demand response unit (`DISPATCHSUBTYPE = WDR`): those bid the `GEN` direction and
  their response acts as supply, so they are detected as loads with `GEN` bids and not modelled
  (their dispatch is a follow-up gap). Each case gets one aggregated warning.
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
- **Not modelled.** Load FCAS offers are modelled by ADR 0038. A load without FCAS bids is simply not a contributor.
  Ramp floors above availability are checked as for generators.
