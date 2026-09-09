# 0002. `ConstraintTerm`/`FCASRequirement` hold names, not live `Component` references

## Status

Accepted

## Context

`UnitTerm`/`RegionTerm`/`InterconnectorTerm`/`FCASRequirement` each reference a device, area, or
interconnector by name (`String`), resolved against a `System` only at use time (see
`resolve_term_devices`). Holding a live `PSY.Component` reference instead was considered and
rejected, based on a directly confirmed serialization test: a `PSY.Component` field nested
inside a custom `PSY.DeviceParameter` does not get PSY's UUID cross-referencing.
`IS.serialize` embeds the referenced component's entire field set — every field, not a `{"uuid":
...}` pointer — so the same component appears twice in a `System`'s JSON: once as the canonical
registered component, once again duplicated inside the parameter.

## Decision

`ConstraintTerm`/`FCASRequirement` subtypes store plain `String` names. Resolution to a live
component happens once, at ingestion (`resolve_term_devices`), never stored on the term itself.

## Consequences

- JSON round-trips stay exact: a term's name re-resolves against whatever component the reloaded
  `System` actually has, rather than carrying a stale embedded snapshot.
- Any future `DeviceParameter` in this package holding another component must follow the same
  by-name pattern. This is settled; do not reopen without a new PSY-side serialization behavior
  to point to.
