# 0011 `InterconnectorLossModel` is a supplemental attribute of `AreaInterchange`

## Status

Accepted; unit handling amended by [0012](0012-per-unit-storage.md).

## What

- `InterconnectorLossModel <: PSY.SupplementalAttribute` (with an `internal` field and keyword constructor), attached to the `PSY.AreaInterchange` of the same name, so it survives `System` JSON round-trips.
- MNSP interconnectors get a loss model like any other interconnector; neither reader filters on `ICTYPE`.

## How

- `attach_interconnector_losses!(sys, db, as_of)` looks each `AreaInterchange` up in `interconnector_loss_models(db, as_of)` and calls `add_supplemental_attribute!`. An interconnector with no model is skipped and returned in `skipped`, with one aggregated `@warn`, never thrown. The NEMDE build (`nem_system(db, NEMDEConfiguration(); date_range)`) refuses any skipped interconnector with an `ArgumentError`, since NEMDE always applies a loss model.
- `nem_system(db, NEMDEConfiguration(); date_range)` calls it with `first(date_range)`; the regional builder does not.
- Formulations read the model from the `AreaInterchange` and never see `db` or `as_of`.

## Why

- Formulations build from the `System` alone, so everything they need is attached at build.
- Loss is a function of the flow `AreaInterchange` already carries.
- Basslink's `FROMREGIONLOSSSHARE` is malformed in AEMO's data and nempy hardcodes `1.0`. This package attaches what AEMO records; do not treat the difference from nempy as a bug.
