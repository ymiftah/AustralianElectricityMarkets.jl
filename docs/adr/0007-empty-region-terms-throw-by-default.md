# 0007 An empty `RegionTerm` is an error

## Status

Accepted; the `allow_empty_region_terms` escape hatch was removed.

## What

- A `RegionTerm` that resolves to a region with no `Generator`/`Storage` in `sys` makes `add_nem_constraints!` throw one `ArgumentError`. It is never a silent skip.
- A term naming something `sys` lacks (unknown DUID, interconnector or region) is a different case and stays a skip, recorded in `skipped`.

## How

- All empty-region terms are collected across the build, then reported together (constraint name, region, `bid_type`). `sys` is mutated only after the throw point.
- `resolve_term_devices` is a pure lookup; the policy lives in `add_nem_constraints!`.

## Why

- Scanning `SPDREGIONCONSTRAINT` (2015-01 to 2026-07, about 25k rows) found only the five NEM regions, so on a whole-NEM `System` an empty region term cannot arise from ordinary data.
- It arises only when the caller restricted the `System` to a subset of regions, which should be a visible error.
