# 0018. FCAS trapezium scaling (AEMO *FCAS Model in NEMDE* §4)

## Status

Accepted

## Context

NEMDE does not optimise against the bid FCAS trapezium directly. Before optimisation it runs a
pre-processing step (*FCAS Model in NEMDE* §4) that can shrink the trapezium:

- §4.1: for `RAISEREG`/`LOWERREG` only, the telemetered AGC enablement limits replace the bid's
  `EnablementMin`/`EnablementMax` wherever they are more restrictive, and the paired breakpoint
  slides to keep the bid's own slope angle. No scaling if the AGC limit is zero or absent.
- §4.2: for `RAISEREG`/`LOWERREG` only, the telemetered AGC ramp rate × the dispatch interval
  (the "AGC ramping capability") replaces the bid's `MaxAvail` wherever it is more restrictive,
  again sliding both breakpoints to keep the bid's slopes. No scaling if the AGC ramp rate is
  zero or absent.
- §4.3: for every FCAS service on a semi-scheduled unit, the UIGF replaces `EnablementMax`
  wherever it is more restrictive, sliding the high breakpoint. No "zero or absent" exemption -
  a UIGF of `0.0` is a real weather forecast of no output.
- No scaling of any kind applies to a contingency bid from a **scheduled** unit.

`FCASMarket` (ADR-0017) previously read the bid trapezium unmodified via `get_fcas_trapezium`,
so a plant whose AGC telemetry or weather forecast was tighter than its bid was modelled as more
capable than NEMDE actually dispatched it as.

### Which DISPATCHLOAD columns are the right inputs

`DISPATCHLOAD.RAISEREGENABLEMENTMIN`/`MAX` and `LOWERREGENABLEMENTMIN`/`MAX` are documented in
AEMO's Electricity Data Model Report as "the maximum/minimum of bid and telemetered value" -
i.e. already the §4.1 output, not raw AGC telemetry. Feeding an already-min'd/max'd value into
`scale_fcas_trapezium`'s own `max`/`min` against the bid is idempotent (`max(bid, max(bid,
telemetered)) == max(bid, telemetered)`), so using these columns directly as the "AGC
enablement limit" input is correct either way, and is also what they publish as the actual
enablement limits NEMDE used.

`RAISEREGAVAILABILITY`/`LOWERREGAVAILABILITY` looked like the natural §4.2 input by the same
"minimum of bid and telemetered" description, but real cache values (`~/.nemdb_cache`,
`DISPATCHLOAD`, `archive_month=2026-06-01`, 2026-06-04) show the telemetered ramp rate feeding
§4.2 is `RAMPUPRATE`/`RAMPDOWNRATE` - the same column `read_dispatch_limits`/
`set_nem_dispatch_limits!` already reads for energy ramping - not the `*REGAVAILABILITY`
columns:

| DUID | RAMPUPRATE (MW/h) | RAMPUPRATE × 5/60 | RAISEREGAVAILABILITY |
| --- | --- | --- | --- |
| ER01 | 300.0 | 25.0 | 25.0 |
| ER03 | 297.46 | 24.788(3) | 24.78828 |
| ER04 | 299.29 | 24.9408(3) | 24.94087 |

`RAISEREGAVAILABILITY == min(bid MaxAvail, RAMPUPRATE × 5/60)` to within AEMO's own rounding on
every checked row (BASTYAN, BRNDBES1 are bid-limited instead, confirming the `min`). This is
independently confirmed by **nempy** (Gorman et al.,
`src/nempy/historical_inputs/units.py:1291-1453`, `_scaling_for_agc_ramp_rates`): it reads
`DISPATCHLOAD.RAMPUPRATE`/`RAMPDOWNRATE` (via `get_scada_ramp_rates`/`get_unit_initial_conditions`,
both direct `DISPATCHLOAD` reads - `loaders.py:93-96`) and computes
`RAMPMAX = RAMPUPRATE × (5/60)`, never referencing `*REGACTUALAVAILABILITY` (its one reference to
that column, as a consistency check, is commented out). nempy's `_scaling_for_agc_enablement_limits`
(`units.py:1148-1291`) likewise reads `DISPATCHLOAD.RAISEREGENABLEMENTMIN/MAX` and
`LOWERREGENABLEMENTMIN/MAX` directly for §4.1, confirming the column choice above. Its worked
doctests (e.g. `units.py:1163-1177`, `1318-1330`) match this ADR's `scale_fcas_trapezium` formula
exactly when checked by hand.

**Disagreement with nempy, followed AEMO instead:** nempy's zero/absent guard for §4.1
(`units.py:1245,1250,1254,1259,1264,1269,1273,1278`) is `AGC_value > 0.0`, applied to both the
enablement-min and enablement-max legs. Applied literally, that treats a genuinely negative
telemetered `EnablementMin` (real, e.g. `ADPBA1` on 2026-06-04: `RAISEREGENABLEMENTMIN = -6.0`,
a small battery's symmetric regulation range) as "absent" and skips scaling that leg even when
the telemetered value is the more restrictive one. AEMO's text says only "zero or absent", not
"non-positive". `scale_fcas_trapezium` therefore gates on `!isnothing(x) && !iszero(x)`, not
`x > 0.0` - relevant now that this package models a `PSY.Storage` device's regulation bid on
both sides (ADR-0017), where a negative `EnablementMin` is the ordinary case, not an edge case.

### UIGF and "semi-scheduled"

`RenewableDispatch` devices already carry a `UIGF`-derived ceiling
(`set_renewable_pv!`/`set_renewable_wind!`), but in a different convention (normalised by the
device's own `max_active_power`, PSY's `NATURAL_UNITS` scaling-factor idiom) than FCAS values
(per-unit of the system base, no scaling-factor multiplier). `set_fcas_scaling_inputs!` attaches
a dedicated `"fcas_uigf"` series in the FCAS convention instead of reusing that series, and a
device counts as semi-scheduled for §4.3 purely by carrying `"fcas_uigf"`, i.e. by appearing in
`read_uigf`'s result.

`read_uigf` originally took "has a non-NULL `DISPATCHLOAD.UIGF`" as the semi-scheduled test,
mirroring nempy (`_scaling_for_uigf`, `units.py:1501-1508`: `semi_scheduled_units =
ugif_values['DUID'].unique()`). nempy's UIGF values come from the NEMDE XML case file
(`xml_cache.py` `get_UIGF_values`), where only semi-scheduled traders carry a `@UIGF`
attribute, so the test is sound there. It is wrong for `DISPATCHLOAD`: it publishes `UIGF = 0`, not `NULL`, for
scheduled and non-scheduled units. On 2026-06-04 00:00-01:00 all 298 scheduled and 60
non-scheduled DUIDs had `UIGF = 0`; the 207 semi-scheduled ones had 87 positive and 120 zero
(solar overnight, a real forecast). Every scheduled unit therefore got a zero `"fcas_uigf"`,
§4.3 clamped its `EnablementMax` to zero, and enabled generator FCAS `(device, t)` pairs on the
real-data window fell from 3,418 to 52. The value cannot tell the two apart, since a
semi-scheduled forecast of `0.0` is real, so `read_uigf` classifies by
`DUDETAILSUMMARY.SCHEDULE_TYPE = 'SEMI-SCHEDULED'`, version-matched on `START_DATE`/`END_DATE`
per interval (the same convention as the constraint-term reader's `DUDETAILSUMMARY` join).

## Decision

- `scale_fcas_trapezium(trap; agc_enablement_min, agc_enablement_max, agc_max_avail, uigf,
  is_regulation)` (`src/fcas/scaling.jl`) is the pure §4 arithmetic: each bound is replaced only
  when the input is more restrictive, and the paired breakpoint is recomputed from the *bid's
  own* slope coefficients (`get_lower_slope_coeff`/`get_upper_slope_coeff`) and the final
  enablement/`MaxAvail` values - algebraically equivalent to applying each scaling step in
  sequence (each step alone provably preserves the other's slope, since a step that moves an
  enablement bound shifts its paired breakpoint by the same delta, leaving the slope ratio
  unchanged), but computed in one pass rather than three intermediate `FCASTrapezium`s.
- `set_fcas_scaling_inputs!(sys, db, date_range)` (`src/setters/fcas_scaling.jl`) attaches six
  per-device `SingleTimeSeries` (`"fcas_agc_enablement_min/max_RAISEREG/LOWERREG"`,
  `"fcas_agc_max_avail_RAISEREG/LOWERREG"`, MW/h ramp rates converted to MW over the interval by
  the same `interval_hours` pattern as `set_nem_dispatch_limits!`) plus `"fcas_uigf"`, read via
  the new `read_fcas_scaling_inputs` (mirrors `read_dispatch_limits`'s shape) and the existing
  `read_uigf`. A device with an incomplete series over `date_range` (any missing interval or
  value) is left without that series entirely, rather than partially attached - reading it back
  then finds the series absent, which is exactly AEMO's "zero or absent ⇒ no scaling" rule.
- `get_scaled_fcas_trapezium` (`src/fcas/access.jl`) reads a device's bid trapezium
  (`get_fcas_trapezium`) and whichever scaling series are attached, and applies
  `scale_fcas_trapezium` per interval. `FCASMarket`'s `_fcas_series`
  (`AustralianElectricityMarketsSimulations/src/fcas_market.jl`) calls this instead of
  `get_fcas_trapezium` - its only change for this ADR.
- `AustralianElectricityMarketsSimulations`'s single-interval replication path
  (`src/replication/preprocessing.jl`, unrelated to `FCASMarket`) had its own duplicate of the
  §4.2/§4.3 arithmetic; `scale_trapezium` there is now a thin wrapper over
  `scale_fcas_trapezium`, unchanged in behaviour (confirmed by its existing tests) and not
  extended with §4.1 - that path has no telemetered AGC enablement input wired up.

## Consequences

- A `System` built without `set_fcas_scaling_inputs!` behaves exactly as before this ADR:
  `get_scaled_fcas_trapezium` finds no scaling series and returns the bid trapezium unchanged.
  Scaling is opt-in per `System`, not a change to `set_fcas_bids!`'s own output.
- Contingency bids on a scheduled unit are never scaled, matching AEMO; a semi-scheduled unit's
  contingency bids are still scaled by UIGF alone (§4.3 applies regardless of service).
- The zero/absent guard is interpreted as exact `0.0` or `missing`, not "non-positive" - a
  deliberate, cited departure from nempy, needed for `PSY.Storage` regulation bids with a
  negative `EnablementMin`.
- §6.1 joint ramping (ADR-0017's known gap) still is not modelled; trapezium scaling narrows the
  *bounds* the joint capacity constraint and `MaxAvail` see, it does not add ramping itself.
