# 0003 No `DYNAMICRHS`, no `GENERICCONSTRAINTRHS`

## Status

Accepted

## What

- Nothing downstream of ingestion reads `GENCONDATA.DYNAMICRHS`, and `GENERICCONSTRAINTRHS` is not ingested.
- A constraint's RHS is the run `DISPATCHCONSTRAINT.RHS` for each `(SETTLEMENTDATE, GENCONID)`.

## How

- `read_invoked_constraints` supplies the RHS series that `add_nem_constraints!` attaches to each `GenericConstraint`.
- The raw `DYNAMICRHS` column is still cached faithfully.

## Why

- AEMO's MMS Data Model Report documents `DYNAMICRHS` as "Not used"; NEMDE's RPN RHS engine does not consult it.
- The package runs the outcome NEMDE enforced and does not re-implement RHS derivation.
- Explaining why an RHS took a value is a separate feature and needs its own ADR.
