# 0087. The AGC ramp rate is derived from published regulation availability

## Status

Accepted.

## Context

AEMO *FCAS Model in NEMDE* §4.2 and §6.1 scale a regulation trapezium and bound joint ramping with the
unit's telemetered AGC ramp rate. NEMDE case files carry it as `SCADARampUpRate`/`SCADARampDnRate`. No
such column was found in the MMSDM data model reference, so it is not in NEMWEB. NEMDE XML is used for
validation only.

`DISPATCHLOAD.RAMPUPRATE`/`RAMPDOWNRATE` is the lesser of the bid and telemetered rates. Filling the AGC
ramp series from it therefore caps regulation at the bid rate, which NEMDE does not do.

Validation on 11 cached June 2026 case files:

- `RAMPUPRATE = min(bid, SCADA)` in 2458 of 2458 unit-intervals.
- The published regulation availability equals `min(bid MAXAVAIL, SCADA/12)` (both sides' MAXAVAIL summed
  for batteries) in 758 of 758 raise and 765 of 765 lower unit-intervals.

So `min(side MAXAVAIL, rate/12)` reproduces NEMDE's regulation cap, and the availability carries the
telemetered rate.

## Decision

The AGC ramp series for each regulation side is the larger of the `DISPATCHLOAD` ramp rate and the
side's regulation availability spread over the interval:

    rate = max(RAMPUPRATE, RAISEREGAVAILABILITY / interval_hours)    # raise
    rate = max(RAMPDOWNRATE, LOWERREGAVAILABILITY / interval_hours)  # lower

A missing ramp rate stays missing. A missing availability falls back to the ramp rate. Trapezium scaling
and joint ramping both read this one series.

## Departure from AEMO

The derived rate is a lower bound on the telemetered rate. Joint ramping can therefore be tighter than
NEMDE's. Against the validation files, the derived raise rate is below the true rate in 27 of 417
generator and 270 of 341 battery unit-intervals. It is never above the true rate, and never tighter than
using `RAMPUPRATE` alone. The regulation cap itself is exact.

## Alternatives

Keeping `RAMPUPRATE` caps regulation at the bid rate, which NEMDE does not do. Reading the SCADA rate
would need a source that MMSDM does not publish.

## Consequences

- The `"fcas_agc_ramp_rate_*"` series no longer equals `DISPATCHLOAD.RAMPUPRATE`/`RAMPDOWNRATE`.
- Energy ramp limits in `dispatch_limits.jl` still read `RAMPUPRATE`/`RAMPDOWNRATE` unchanged.
- Joint ramping may bind where NEMDE does not, by the gap described above.
