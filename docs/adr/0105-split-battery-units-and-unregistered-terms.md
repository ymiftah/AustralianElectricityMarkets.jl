# 0105. Split-battery generator units are built, dropped terms of unregistered units are allowed

## Status

Accepted. Refines [0104](0104-vacuous-constraints-on-retired-units.md).

## Context

The nempy benchmark replays intervals of the second half of 2024. A replay of 2024-10-05 failed the
dropped-terms check of `nem_system` with 506 unit terms in 308 built constraints on eight DUIDs: `RESS1G`,
`LBBG1`, `TB2BG1`, `CHBESSG1`, `WDBESSG1`, `BBATTERY`, `CAPBES1G` and `CAPBES1L`.

The first guess was that these were batteries already re-registered as bidirectional units (IESS), so
retired. `DUDETAILSUMMARY` says otherwise for six of them: on 2024-10-05 `RESS1G`, `LBBG1`, `TB2BG1`,
`CHBESSG1`, `WDBESSG1` and `BBATTERY` are registered `GENERATOR`, `SCHEDULED` units (registrations ending
between 2024-10-10 and 2024-12-11). Each has 289 `DISPATCHLOAD` rows and energy and FCAS offers that day.
They are the generator halves of batteries still registered as a separate scheduled generator and
scheduled load. Only `CAPBES1G` and `CAPBES1L` are not registered on that day.

The six were absent from the `System` because neither builder took them. `get_batteries_dataframe` keeps
units with a battery energy source and storage efficiency, which the generator half lacks. The generator
builder maps a battery energy source to the `BA` prime mover, which no generator type accepts.

## Decision

### 1. The generator half of a split battery is a scheduled generator

In a replay network a unit with the `Battery Storage` energy source and `DISPATCHTYPE = GENERATOR` is
built as a `ThermalStandard` with prime mover `BA`, limits from its registration like any other scheduled
generator. Its load half is a `DISPATCHTYPE = LOAD` unit, already built as a scheduled load. NEMDE
dispatches the two halves as separate units, each with its own energy offer, FCAS offers and dispatch
target, which is what the two devices model. No state of charge links them, as none links a
bidirectional unit in this replay.

Regional (energy-only, ISP cost) networks do not build them: there they would be a zero-cost generator
with no energy limit.

### 2. A dropped term of a unit not registered over the range is allowed

The constraint builder records, for each dropped unit term, whether `DUDETAILSUMMARY` registers the unit
at some interval of the build range (`registered` in `get_dropped_terms`). The checks of `nem_system`
and `check_template_against_sys` fail only on dropped terms of registered units. A term of a unit not
registered over the range contributes zero, as nempy does for a unit outside the dispatch. A registered
unit missing from the `System` is a build defect and stays an error.

`check_template_against_sys` also accepts `:vacuous_unknown_duid` skips, as `nem_system` already did.

## Consequences

- 2024-10-05 builds and replays: six intervals from 12:05 give an energy price MAE of $0.017/MWh against
  NEMDE.
- The 2026 replay gates are unchanged: no split battery is registered in 2026.
- A unit absent from `DUDETAILSUMMARY` entirely counts as unregistered, so its terms are dropped
  without error.

## Market correctness

No bound, constraint or cost term changes. Each split-battery generator half is dispatched within its own
offer and availability like any scheduled generator. A constraint term on a unit not registered at the
interval has no dispatch variable in NEMDE either.
