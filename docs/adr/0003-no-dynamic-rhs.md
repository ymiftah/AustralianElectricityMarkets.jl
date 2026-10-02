# 0003. Do not interpret `GENCONDATA.DYNAMICRHS`, and do not ingest `GENERICCONSTRAINTRHS`

## Status

Accepted

## Context

`GENCONDATA.DYNAMICRHS` is a column on AEMO's generic constraint definition table. AEMO's own
MMS Data Model Report documents it as "Not used" — it is a vestige of an older constraint RHS
mechanism, not something NEMDE's Reverse Polish Notation (RPN) RHS engine consults when
computing the RHS actually enforced at a dispatch interval.

Separately, and more decisively for this package: `AustralianElectricityMarkets.jl` does not
compute or derive constraint RHS values at all. It replays `DISPATCHCONSTRAINT.RHS` — the
exact number NEMDE used for a given `(SETTLEMENTDATE, GENCONID)` at each dispatch interval (see
`read_invoked_constraints`). Given that, *why* the RHS took a particular value is irrelevant to
this package's purpose, even in the cases where AEMO's systems do record that reason correctly
somewhere. We are consumers of the outcome, not re-implementers of NEMDE's RHS derivation.

## Decision

- Do not read or interpret `GENCONDATA.DYNAMICRHS` anywhere in the reader/builder path
  (`read_constraint_definitions`, `add_nem_constraints!`, the `GenericConstraint` docstring).
  The raw NEMWEB ingestion column list is left untouched — the column is still cached
  faithfully — but nothing downstream of ingestion looks at it.
- Do not ingest `GENERICCONSTRAINTRHS` either. It is the other table someone might reach for
  when asking "where does the RHS come from"; it is subject to the same reasoning above and is
  out of scope for the same reason `DYNAMICRHS` is.

## Consequences

- Anyone asking "where does this constraint's RHS come from" should be pointed at the replayed
  `DISPATCHCONSTRAINT.RHS` time series (see `add_nem_constraints!` and the `GenericConstraint`
  docstring), not at a new ingestion path for `GENERICCONSTRAINTRHS` or at `DYNAMICRHS`.
- If a future need arises to explain *why* an RHS took a given value (rather than replay what
  it was), that is a distinct feature and should get its own ADR revisiting this decision rather
  than quietly reintroducing `DYNAMICRHS`/`GENERICCONSTRAINTRHS` ingestion.
