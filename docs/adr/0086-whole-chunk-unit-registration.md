# 0086 Units registered at any point of a replay chunk are built for the whole chunk

## Status

Accepted.

## What

- A chunk spans one trading day (interval-ending stamps 04:05 to 04:05 next day, 289 stamps). NEMWEB registers units at midnight, so a unit registered or deregistered mid-chunk has bid and dispatch rows for only part of it.
- A unit is registered at stamp `t` when `registered_from < t <= registered_until` (`_is_registered`), the span of its `DUDETAILSUMMARY` rows. The unit set is every unit registered at some stamp of the chunk.
- Each unit takes its attributes from its earliest overlapping `DUDETAILSUMMARY` row and its `DUDETAIL` version in force at the later of the chunk start and that row's start (`read_units(db; as_of, through)`).
- Every per-unit series spans the whole chunk. Outside the registration it holds zero `MAXAVAIL`, `UIGF`, `INITIALMW`, ramp rates and availability, a zero FCAS trapezium and zero-width offer curves. A padded trapezium has `NaN` ramp rates, which `FCASTrapezium` reads as absent.
- A missing row inside a registration, or a missing energy offer, stays an error. A non-scheduled load is exempt: all its values are zero.
- A unit's loss factor is the earliest row registered in the chunk, with a warning when factors differ inside it. A unit whose `REGIONID`, `DISPATCHTYPE` or `SCHEDULE_TYPE` changes inside the chunk is an error.
- A schedule type applies at `t` when `START_DATE < t <= END_DATE`, so a unit deregistered at a stamp keeps its schedule type there.
- Bid or FCAS rows at stamps outside the replay grid are an error, never dropped.
- `RegionalNetworkConfiguration` keeps its as-of selection.

## Why

- Splitting the chunk at midnight would break the single-build replay interface and still need padding for FCAS-only and partly published units.
- Padding is exact only because a padded unit contributes nothing (zero `MAXAVAIL` bounds its energy, its FCAS offer is disabled, its ramps are zero), so the padded series must not be reused for anything else.
- Loss factors are one value per chunk; the 1 July change is respected by the chunk split.
