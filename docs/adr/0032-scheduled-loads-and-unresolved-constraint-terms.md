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
