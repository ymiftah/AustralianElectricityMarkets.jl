# 0086. Units registered at any point of the replay chunk are built for the whole chunk

## Status

Accepted.

## Context

A replay chunk spans one trading day: interval-ending stamps from 04:05 on the day to 04:05 on the next
day, 289 in all. Units are registered in NEMWEB at midnight, so a unit registered on the next day
appears in the chunk's bids and dispatch rows from 00:05 but was absent from the system, which was built
from the units in force at the first stamp. Five days failed on this: 2026-02-17 (NESBESS1 and NESBESS2
registered 02-18), 2026-03-24 (BRDDBES1 registered 03-25), 2026-02-24 (a non-scheduled load whose rows end
at 00:00 on 02-25 and a scheduled load registered 02-25), 2026-05-11 (FCAS offers published only from
00:05 on 05-12, so 48 values for 289 stamps) and 2026-02-09 (a battery whose FCAS offers start at 00:05
on 02-10). The first two dropped units and their constraint terms; the others produced series shorter
than the chunk, labelled from its first stamp.

## Decision

A unit is registered at an interval-ending stamp `t` when `REGISTERED_FROM < t <= REGISTERED_UNTIL`,
the span of its `DUDETAILSUMMARY` rows. The unit set of a chunk is every unit registered at some stamp
of the chunk. Each unit takes its attributes from its earliest overlapping `DUDETAILSUMMARY` row, and its
`DUDETAIL` version in force at the later of the chunk start and that row's start.

Every per-unit series spans the whole chunk. Outside a unit's registration it holds zero energy
`MAXAVAIL`, `UIGF`, `INITIALMW`, ramp rates and `AVAILABILITY`, and a zero FCAS trapezium (zero
`MAXAVAIL`), with zero-width energy and offer curves. A missing row inside a registration is still an
error, as is a missing energy offer. A non-scheduled load is exempt from these missing-row checks: every
value it is given is zero, so its DISPATCHLOAD and offer rows need not exist.

A loss factor is taken from the earliest row registered in the chunk and warns when the factors differ
inside it. A unit whose REGIONID, DISPATCHTYPE or SCHEDULE_TYPE changes inside the chunk is an error,
because one unit cannot change region or dispatch type within a single system. The
RegionalNetworkConfiguration path keeps its as-of selection.

The schedule type of an energy offer is read with the same registration rule: a `DUDETAILSUMMARY` row's
schedule type applies at `t` when `START_DATE < t <= END_DATE`. A row starting at a stamp does not yet
apply there, and the row ending at it still does, so a unit deregistered at a stamp keeps its schedule
type there.

## Alternatives

Splitting the chunk at midnight would give each unit a constant set of stamps. It changes the replay's
single-build interface, and it would still need padding for FCAS-only and partly published units, so
it is rejected.

## Consequences

- Padding is exact only because a padded unit contributes nothing: its energy variable is bounded by a
  zero `MAXAVAIL`, its FCAS effective offer is disabled, and its ramp series are zero. The padded
  ramp series must not be reused for anything else.
- A unit's loss factor is one value per chunk. Factors change at 1 July, which the chunk split already
  respects. Of the 28 other loss-factor changes since 2021-10, the window warns on each one that falls
  inside a chunk.
- A unit changing REGIONID, DISPATCHTYPE or SCHEDULE_TYPE inside a chunk fails the build. Since 2021-10
  REGIONID changed mid-chunk four times, among them DRXNDB04 and HAUGHTSS.
- A padded FCAS trapezium has NaN ramp rates, which `FCASTrapezium` reads as absent.
- Padded stamps are the only ones that change. A full-registration day is expected to build as before.
- Energy bid rows, and FCAS trapezium and offer-curve rows, at stamps outside the replay grid are an
  error rather than being dropped, as they would otherwise misalign a series.
