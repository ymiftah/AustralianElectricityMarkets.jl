# 0074 Aggregate dispatch limits onto the model resolution

## Status

Accepted

## What

- `read_dispatch_limits(db, date_range; intervention, resolution)` ceils the five-minute `DISPATCHLOAD` rows onto `resolution`; `nem_system` passes the step of `date_range`.
- Per bucket: `INITIALMW` is the first interval's value (metered MW at period start); `RAMPUPRATE`, `RAMPDOWNRATE` and `AVAILABILITY` are the minimum across the intervals.
- At five minutes the result is unchanged.

## How

- A missing value propagates, so the missing-data check still rejects the device.
- The ramp-down floor (`INITIALMW - RAMPDOWNRATE * interval_hours`) uses the step length and holds at any resolution.

## Why

- A coarser model step (for example 30 minutes) otherwise finds no exact settlement timestamp and throws.
- The minimum is this project's choice, not an AEMO rule: it is the most restrictive limit NEMDE applied in the period. Mean or end-of-period values would change ramp and envelope limits.
- The model cannot represent intra-period ramping or availability shape.
