# 0016. Dispatch limits follow NEMDE's units and envelope, not an assumed convention

## Status

Accepted

## Context

A real-data integration suite (`AustralianElectricityMarketsSimulations/test/real_data/runtests.jl`)
ran the formulation against a local NEMWEB cache for 2026-06-04 and checked it against what NEMDE
actually dispatched, rather than against an assumed convention. It found three problems, all
against real `DISPATCHLOAD` data and only against dispatch *targets* (`TOTALCLEARED`); dispatch
*prices* were not checked.

### Ramp rates are MW per hour, not MW per minute

Across 162,418 `DISPATCHLOAD` rows for the day, the 99.9th percentile of a 5-minute move
(`TOTALCLEARED - INITIALMW`) divided by `RAMPUPRATE` is `0.0833`, exactly `5/60`, and the same
holds downward against `RAMPDOWNRATE`, so `RAMPUPRATE`/`RAMPDOWNRATE` are MW per hour. `energy_bounds`
already treated them that way, but `set_nem_dispatch_limits!` stored them directly into
`"ramp_up_rate"`/`"ramp_down_rate"`, and both the series' own docstrings and
`RampUpRateTimeSeriesParameter`/`RampDownRateTimeSeriesParameter` in
`AustralianElectricityMarketsSimulations` called them per-minute. The formulation's
`RampConstraint` multiplies the stored rate by the interval length in minutes, so every ramp band
was 60 times too wide.

### A ramp-down floor above availability is a real, recorded outcome

Define the ramp-down floor as `INITIALMW - RAMPDOWNRATE × Δ`, Δ the interval in hours. Of 526
rows that day where the floor exceeded `AVAILABILITY` by more than 0.01 MW, across 21 units, 402
were cleared at the floor, above `AVAILABILITY`. No row was cleared above
`max(AVAILABILITY, floor)`; the largest excess was 0.00013 MW.

Every row cleared below the floor (123) belonged to `KEPBL1` or `KEPBG1`, where `AVAILABILITY`
won. They are the charging and generating DUIDs of one `NON-SCHEDULED` bidirectional asset, and
the System this package builds contains neither; only `KEPWF1` and `KEPSF1`, at the same site, are
modelled. Every other unit in that state was cleared at its floor.

`set_nem_dispatch_limits!` stored `"max_active_power"` from `AVAILABILITY` alone, so the model's
upper dispatch limit could sit below the unit's own ramp-down floor: infeasible by construction
whenever real data hit this case. `_check_dispatch_envelope`
(`AustralianElectricityMarketsSimulations/src/nem_dispatch.jl`) correctly reported this as an
inconsistent envelope at build time — the guard was never wrong, the input it was checking was.
Separately, `AustralianElectricityMarketsSimulations/src/replication/preprocessing.jl`'s
`energy_bounds` resolved the same conflict the wrong way, with `lower = min(lower, upper)`
letting `MAXAVAIL` pull the lower bound down below the ramp-down floor instead of letting the
upper bound rise to it.

### The strict setter demanded data for unavailable units

`set_nem_dispatch_limits!` and `set_nem_initial_conditions!` throw when any device
`_nem_dispatch_devices(sys)` selects has no usable `DISPATCHLOAD` data. On the same day, 145
devices had no `DISPATCHLOAD` rows at all, and all 145 were units `set_market_bids!` had already
marked unavailable for having no bids. `_nem_dispatch_devices` selected every
`ThermalStandard`/`HydroDispatch`/`RenewableDispatch` regardless of availability, so the strict
setter failed on data AEMO never dispatched in the first place.

## Decision

### Ramp rates are converted to MW/minute at the setter, not reinterpreted at the formulation

`set_nem_dispatch_limits!` divides `RAMPUPRATE`/`RAMPDOWNRATE` by 60 before per-unitising, so the
stored `"ramp_up_rate"`/`"ramp_down_rate"` series match their documented per-minute contract. The
formulation's own multiplication by the interval length in minutes is unchanged.

### The upper dispatch limit is `AVAILABILITY` raised to the ramp-down floor

`set_nem_dispatch_limits!`'s `"max_active_power"` series becomes
`max(AVAILABILITY, INITIALMW - RAMPDOWNRATE × Δ)`, normalised by the static rating as before, Δ
taken from the `date_range` step. `energy_bounds` applies the same rule to its upper bound:
`min(initial + ramp_up × Δ, max(max_avail, initial - ramp_down × Δ))`, instead of capping the
upper bound at `max_avail` unconditionally and then clamping the lower bound down to match.

The rule lives in the data series, not as a build-time constant or a one-off exception in the
formulation: `"max_active_power"` is still a single per-device, per-interval number the
formulation reads as a plain upper bound, so the model stays linear and parameter-driven. If
`DISPATCHLOAD` is re-read after a parameter change between solves, the envelope is derived fresh
from the current `INITIALMW`/`RAMPDOWNRATE`/`AVAILABILITY` rather than depending on a decision
frozen at an earlier build.

`_check_dispatch_envelope` is unchanged: it remains a guard against a hand-built series where the
floor genuinely exceeds the upper dispatch limit, which is still infeasible. It does not fire on
`set_nem_dispatch_limits!`'s own output, since that now always satisfies
`max_active_power >= floor` by construction, within its existing floating-point tolerance.

### `_nem_dispatch_devices` selects only available devices

`_nem_dispatch_devices(sys)` filters on `get_available`, so a device already marked unavailable —
by `set_market_bids!` for having no bids, or by any other caller — is excluded from both
`set_nem_dispatch_limits!` and `set_nem_initial_conditions!` rather than forcing every caller to
supply `DISPATCHLOAD` data for units nobody dispatched.

## Consequences

- Every ramp band computed by the formulation is 60 times narrower than before this fix. Any
  System built before this change and cached in a serialised `System` JSON needs its dispatch
  limits re-set, not merely re-read.
- A caller that wants a device's ramp-down floor and `AVAILABILITY` both enforced as hard,
  independent bounds — the pre-fix behaviour — no longer gets that from
  `set_nem_dispatch_limits!`; it must build its own series.
- `set_nem_dispatch_limits!`/`set_nem_initial_conditions!` silently skip unavailable devices.
  A device meant to participate that was marked unavailable by mistake elsewhere no longer causes
  either setter to fail loudly; it is simply excluded.
- Only dispatch targets were checked against real data, not clearing prices. A future check
  against `DISPATCHPRICE`/FCAS co-optimisation is not covered by this ADR's evidence.
