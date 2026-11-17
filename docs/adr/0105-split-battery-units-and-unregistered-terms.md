# 0105 Split-battery generator units are built, dropped terms of unregistered units are allowed

## Status

Accepted. Refines [0104](0104-vacuous-constraints-on-retired-units.md).

## What

- In a NEMDE network, a unit with the `Battery Storage` energy source (prime mover `BA`) and `DISPATCHTYPE = GENERATOR` is built as a `ThermalStandard` with its limits from its registration. Its load half (`DISPATCHTYPE = LOAD`) is a scheduled load. Regional (energy-only) networks do not build the generator half.
- Dropped terms of a unit not registered over the build range (`DUDETAILSUMMARY`; a unit absent from it counts as unregistered) are allowed and contribute zero. Dropped terms of a registered unit always fail `nem_system` and `check_template_against_sys`, including those of vacuous constraints.
- `check_template_against_sys` accepts `:vacuous_unknown_duid` skips, as `nem_system` does.

## How

- `get_generators_dataframe` flags such units `legacy_battery`; the thermal builder takes them when the network allows legacy batteries. `get_batteries_dataframe` keeps only units with battery storage data, which the generator half lacks.
- The constraint builder records `registered` for each dropped term (`get_dropped_terms`); the checks filter on it.

## Why

- Many batteries stayed registered as a separate scheduled generator and load until their IESS re-registration (2024 to 2025). NEMDE dispatches the halves as separate units, each with its own offers and dispatch target. No state of charge links them, as none links a bidirectional unit in this run.
- A registered unit missing from the `System` is a build defect; an unregistered unit has no dispatch variable in NEMDE either, as nempy also treats a unit outside the dispatch.

## Market correctness

No bound, constraint or cost term changes. Each generator half is dispatched within its own offer and availability like any scheduled generator.
