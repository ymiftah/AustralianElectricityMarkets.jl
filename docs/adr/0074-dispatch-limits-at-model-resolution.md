# 0074. Aggregate dispatch limits onto the model resolution

## Status

Accepted.

## Context

`set_nem_dispatch_limits!` read `DISPATCHLOAD` at its native five-minute interval and looked each step
of `date_range` up as an exact settlement timestamp. A model at a coarser step, such as the 30-minute
horizon in the clearing-with-batteries example, found no row for most steps and threw. `DISPATCHLOAD`
is one row per five-minute interval. `INITIALMW` is the metered MW at the start of the interval; the
ramp rates and `AVAILABILITY` are the values NEMDE applied in it (`references/data-model/DISPATCHLOAD.md`).
AEMO does not define how to collapse them onto a longer period.

## Decision

`read_dispatch_limits` takes a `resolution`. The step of `date_range` is passed through by
`set_nem_dispatch_limits!`. Rows are ceiled onto the resolution, so a bucket holds the intervals that end
inside it. Per bucket:

- `INITIALMW` is the value at the first interval, the metered MW at the start of the period.
- `RAMPUPRATE`, `RAMPDOWNRATE` and `AVAILABILITY` are the minimum across the intervals, the most
  restrictive value NEMDE applied in the period.

A bucket with a missing value propagates `missing`, so the existing "missing data is a problem" check still
rejects the device. The minimum is this project's choice, not an AEMO rule. Taking the mean, or the value at
the period's end, would be equally defensible and would change the ramp and envelope limits.

## Consequences

- A model at a coarser step can attach dispatch limits. At five minutes the result is unchanged.
- Within a period the model cannot represent intra-period ramping or the availability shape. It sees the
  binding limit for the whole period.
- The ramp-down floor (`INITIALMW - RAMPDOWNRATE * interval_hours`) uses the step's length, so it
  already holds at any resolution.
