# 0004 Constraint identity is `(GENCONID, EFFECTIVEDATE, VERSIONNO)`

## Status

Accepted

## What

- One `GenericConstraint` per exact `(GENCONID, EFFECTIVEDATE, VERSIONNO)` triple invoked in `date_range`, not per `GENCONID`.
- Named `GENCONID@yyyy-mm-dd#VERSIONNO`; the bare id is the `gencon_id` field (`get_gencon_id`).

## How

- `add_nem_constraints!` iterates the distinct invoked triples of `DISPATCHCONSTRAINT`. Definitions, terms and the `rhs`/`invoked` series are all taken per triple; `read_constraint_terms` carries `EFFECTIVEDATE` and `VERSIONNO` through.
- A version's `invoked` series is 1 only where `DISPATCHCONSTRAINT` selected that exact version.
- `added` and `skipped` are keyed by the versioned name.
- Exception: `fcas_requirements` match on bare `GENCONID` and attach to every version.

## Why

- AEMO revises sense, terms and coefficients across versions under one `GENCONID`. Keying by id merged different equations into one LP row.
- Measured on 2026-07 data: 178 of 6258 ids ran under more than one version (up to 7), 96 switches mid-day.
- `DISPATCH_FCAS_REQ_CONSTRAINT` has no version columns on recent data (`GENCONEFFECTIVEDATE` and `GENCONVERSIONNO` are `NULL`), so a version-exact join would drop all FCAS attribution. This is an AEMO data limitation.
