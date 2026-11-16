# 0001 `GenericConstraint` is a `PSY.Service`

## Status

Accepted

## What

- `GenericConstraint <: PSY.Service`, not a `PSY.Component` or a `PSY.Reserve`.
- `sense` is a struct field, not a type parameter.

## How

- `add_nem_constraints!` attaches each constraint with `add_service!(sys, gc, devices)`, where `devices` is the union of its terms' contributors: a `UnitTerm` or `InterconnectorTerm` names one device, a `RegionTerm` every `Generator`/`Storage` in its region.
- Contributors are resolved once at ingestion by `resolve_term_devices`. Empty-region policy is in [0007](0007-empty-region-terms-throw-by-default.md).

## Why

- A constraint's LHS spans units, a regional aggregate and an interconnector flow, and one constraint can govern several `(region, service)` prices. No `Reserve` subtype has that shape.
- Membership lives in the `System`, so PSI's `ServiceModel` machinery drives constraints without re-deriving which devices contribute.
- `sense` is a per-instance runtime fact (`GENCONDATA.CONSTRAINTTYPE`) used at one call site; a type parameter would fragment the type for no dispatch benefit.
