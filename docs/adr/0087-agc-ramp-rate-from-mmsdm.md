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
generator and 270 of 341 battery unit-intervals. It is never above the true rate, and never lower than `RAMPUPRATE`, so joint ramping is at least as
loose as before wherever `RAMPUPRATE` is positive. Where `RAMPUPRATE` is 0, for example STAN-1 and
STAN-2 bidding `ROCDOWN = 0` (110 rows in June and July 2026), the old rate meant no scaling and no
joint row, while the derived rate now applies both. On the two such rows with case files the new cap
is exact, and NEMDE's solution violates the new row in 0 of 110 rows. The regulation cap itself is
exact.

The departure from nempy is that nempy takes the ramp rate from the XML `SCADARampUpRate` and
`SCADARampDnRate`. This replay reads XML for validation only, so the rate comes from the availability
instead. This decision supersedes the `RAMPUPRATE` choice in ADR 0018 and the matching text in ADR 0017.

## Evidence

- The per-side cap is exact on 111 case files (about 21,000 side rows), with the largest difference
  under 0.0005 MW.
- The derived rate is below the true rate for lower in 30 of 417 generator and 277 of 348 battery
  unit-intervals.
- June and July 2026 dispatch: cleared regulation is above the derived cap in 0 of about 454,000 rows
  (158 with the old rate). NEMDE's solution violating the joint row went from 861 to 725 for raise and
  from 566 to 167 for lower, none of them on batteries.

## Known gap

Availability 0 with a bid and a positive ramp (32 raise and 33 lower rows on STAN and TARONG units,
June and July 2026) keeps the ramp as the rate, unchanged from before. The cause is unknown.

## Replays

At 2026-01-22 06:25 and 2026-02-17 22:40 the Tasmanian regulation shortfalls are gone. The day FCAS
price maximum error on 2026-01-22 fell from 202,981 to 2.4 $/MWh.

## Alternatives

Keeping `RAMPUPRATE` caps regulation at the bid rate, which NEMDE does not do. Reading the SCADA rate
would need a source that MMSDM does not publish.

## Consequences

- The `"fcas_agc_ramp_rate_*"` series no longer equals `DISPATCHLOAD.RAMPUPRATE`/`RAMPDOWNRATE`.
- Energy ramp limits in `dispatch_limits.jl` still read `RAMPUPRATE`/`RAMPDOWNRATE` unchanged.
- Joint ramping may bind where NEMDE does not, by the gap described above.
