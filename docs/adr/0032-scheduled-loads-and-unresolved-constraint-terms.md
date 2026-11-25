# 0032 Scheduled loads and unresolved generic-constraint terms

## Status

Accepted. Unregistered-unit terms and vacuous constraints are refined by [0104](0104-vacuous-constraints-on-retired-units.md) and [0105](0105-split-battery-units-and-unregistered-terms.md); load FCAS by [0038](0038-load-fcas-offers.md).

## What

- A generic-constraint term on a unit absent from the `System` is dropped and the constraint is built from the rest; the term is recorded in the build report, read with `get_dropped_terms(sys)` (kind, key, `BIDTYPE`, factor).
- An unresolved region or interconnector term skips the constraint, as does a constraint with no resolvable term; the skip reason is the kind of the first unresolved term.
- Scheduled loads (`DISPATCHTYPE = LOAD`) are `InterruptiblePowerLoad` devices on `<REGION>_GEN_BUS`, dispatched as consumed MW.

## How

- Loads are read from `DUDETAILSUMMARY`; `get_generators_dataframe` excludes `DISPATCHTYPE = LOAD` so a DUID never names both a generator and a load.
- A load has a decremental `MarketBidCost` from the `LOAD` direction of the bid tables, band order reversed as for a battery's load side. A load with no bid, or a wholesale demand response unit that bids `GEN` (`DISPATCHSUBTYPE = WDR`), is unavailable with one aggregated warning (WDR dispatch is not modelled).
- The load reuses the `AbstractNEMDispatch` `ActivePowerVariable`, bounded by `AVAILABILITY`, ramped against `INITIALMW` (consumed MW, positive) and priced like a battery's charge. Only its balance multiplier is -1.
- Area balance stays at `TOTALDEMAND`, so generation clears at demand plus scheduled load. The load is not a `PowerLoad`, so the demand series and loss demand are unchanged.
- A load enters a constraint LHS as positive consumed MW with multiplier +1; the constraint's own factor carries the sign. A `RegionTerm` of `ENERGY` still aggregates generators and storage only.

## Why

- `TOTALDEMAND` is "demand (less loads)" and `DISPATCHABLELOAD` is "added to total demand to get inherent region demand" (MMS Data Model, `DISPATCHREGIONSUM`), so the load is a withdrawal on top of demand.
- Generators and loads both enter a constraint LHS as positive MW (Constraint Implementation Guidelines 2.2; the factor carries the sign, 3.2.2).
- Dropping follows nempy, which inner-merges constraint terms onto unit variables so a term with no variable contributes nothing (`solver_interface.py`).

## Departure from AEMO

- NEMDE's case holds every registered unit, so no term is ever missing. Dropping is exact only when the unit's dispatch is zero. The NEMDE-faithful treatment moves `factor * TOTALCLEARED` of a dropped dispatched unit to the right-hand side (Constraint Implementation Guidelines 3.2.1); not implemented.
- Dropped terms of connection-point aliases (`read_constraint_terms` fans a connection point out to every DUID on it) are a known gap.
