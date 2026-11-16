# 0002 Constraint terms hold names, not live components

## Status

Accepted

## What

- `UnitTerm`, `RegionTerm`, `InterconnectorTerm` and `FCASRequirement` store plain `String` names, never a `PSY.Component`.
- Any future `DeviceParameter` in this package that refers to a component follows the same by-name pattern.

## How

- Names are resolved against a `System` at use time by `resolve_term_devices`, once at ingestion.

## Why

- A `PSY.Component` field nested inside a custom `DeviceParameter` gets no PSY UUID cross-referencing: `IS.serialize` embeds the component's full field set, so it appears twice in the `System` JSON.
- By-name terms round-trip exactly and re-resolve against whatever the reloaded `System` holds.
- Do not reopen without a new PSY-side serialization behaviour to point to.
