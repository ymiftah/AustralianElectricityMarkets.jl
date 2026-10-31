# 0011. `InterconnectorLossModel` attaches to `AreaInterchange` as a `SupplementalAttribute`

## Status

Accepted

## Context

[`InterconnectorLossModel`](@ref) and [`interconnector_loss_models`](@ref) (a prior PR) can
resolve every interconnector's NEMDE loss curve from the DB, but a plain `struct` cannot be
added to a `PSY.System` or survive a `System` JSON round-trip. Phase 2 of this redesign builds
formulations purely off the `System` it's handed — it must never open the DB itself — so
whatever a formulation needs has to be attached to the `System` in Phase 1.

`_add_area_interfaces!` already builds one `PSY.AreaInterchange` per `INTERCONNECTORID`; that's
the component a flow-based loss naturally belongs to, since losses are a function of the same
interconnector flow `AreaInterchange` already carries.

AEMO's own `INTERCONNECTORCONSTRAINT.FROMREGIONLOSSSHARE` for Basslink (`T-V-MNSP1`) is not
properly defined in the source data; nempy (a well-known open-source NEM dispatch tool)
hardcodes it to `1.0` rather than trusting the field. This package does not special-case it —
`attach_interconnector_losses!` attaches whatever AEMO's data says, quirk included, since
"correcting" a value this package hasn't independently measured would be inventing data.

MNSP interconnectors get a `PSY.AreaInterchange` and a loss model the same as any other
interconnector: neither `read_interconnectors` nor `_add_area_interfaces!` filters on `ICTYPE`.
MNSP-specific flow *formulation* (as opposed to loss attachment) is a Phase 3 concern, out of
scope here.

## Decision

- `InterconnectorLossModel <: PSY.SupplementalAttribute`, with an `internal` field and a keyword
  constructor, so it can be added to a `System` and round-trips through JSON.
- `attach_interconnector_losses!(sys, db, as_of)` looks up each `PSY.AreaInterchange` already in
  `sys` by name in `interconnector_loss_models(db, as_of)` and calls
  `add_supplemental_attribute!`. An interconnector with no resolvable loss model is skipped and
  collected into one aggregated `@warn`, never thrown.
- Wired into `ConstrainedNetworkConfiguration` as a fourth step, after `add_fcas_services!`, not
  into the base `nem_system` builder (which has no date parameter).

## Consequences

- Phase 2 formulations read a loss model straight off `AreaInterchange`'s supplemental
  attributes; they never need `db` or `as_of`.
- Basslink's loss share is attached as AEMO records it, not as nempy corrects it — a future
  reader comparing dispatch replication against nempy should expect this difference and not
  treat it as a bug in this package.
