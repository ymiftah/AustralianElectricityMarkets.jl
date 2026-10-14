# 0001. `GenericConstraint` is a `PSY.Service`, not a `PSY.Component` or a `PSY.Reserve`

## Status

Accepted

## Context

A NEM generic constraint is `LHS <sense> RHS` — the mechanism AEMO uses for both network limits
and FCAS requirements. Its LHS can reference several units, a regional aggregate, and an
interconnector flow at once, and one constraint can govern several `(region, service)` prices
simultaneously.

As a plain `PSY.Component` it had no relationship to the devices it constrains: a
`PowerSimulations.jl` extension would have to rediscover, for every constraint, which devices
contribute to its LHS.

`PSY.Reserve` was considered and rejected. No `Reserve` subtype has this shape — a reserve is a
requirement over one product for one set of contributors, whereas a generic constraint can span
regions, services and an interconnector flow in a single equation.

## Decision

`GenericConstraint <: PSY.Service`. `add_nem_constraints!` attaches each one with
`add_service!(sys, gc, devices)`, where `devices` is the union of its terms' contributors: a
`UnitTerm`/`InterconnectorTerm`'s single named device, and a `RegionTerm`'s every
`Generator`/`Storage` in that region.

`sense` stays a struct field rather than a type parameter. It is a runtime fact per instance
(`GENCONDATA.CONSTRAINTTYPE`) affecting exactly one call site, not a compile-time modelling
choice, and making it a parameter would fragment the type for no dispatch benefit.

## Consequences

- The device↔constraint relationship lives in the `System`, so a `PowerSimulations.jl` extension
  drives constraints through PSI's own `ServiceModel` machinery instead of re-deriving membership.
- A constraint's contributing devices are resolved once, at ingestion. See
  `docs/adr/0007-empty-region-terms-throw-by-default.md` for the empty-region policy.
- `PSY.Service <: PSY.Component`, so anything that previously fetched a `GenericConstraint` with
  `get_component` keeps working.
