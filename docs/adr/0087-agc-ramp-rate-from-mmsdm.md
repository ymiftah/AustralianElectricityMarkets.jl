# 0087 The AGC ramp rate is derived from published regulation availability

## Status

Accepted. Amends the ramp input of [0017](0017-fcas-market-formulation.md) and [0018](0018-fcas-trapezium-scaling.md).

## What

- AEMO *FCAS Model in NEMDE* §4.2 (trapezium scaling) and §6.1 (joint ramping) use the unit's telemetered AGC ramp rate. NEMDE case files carry it as `SCADARampUpRate`/`SCADARampDnRate`; MMSDM has no such column, and NEMDE XML is for validation only.
- `DISPATCHLOAD.RAMPUPRATE`/`RAMPDOWNRATE` is the lesser of the bid and telemetered rates, so using it would cap regulation at the bid rate, which NEMDE does not do.
- The AGC ramp for each regulation side is the larger of the dispatch ramp rate and the side's effective regulation availability over the interval: `max(ramp, availability / interval_hours)` (`agc_ramp_rate`). The effective availability is `min(bid MAXAVAIL, DISPATCHLOAD.*REGAVAILABILITY)` (`effective_regulation_max_avail`). A `NaN` ramp stays `NaN`; a `NaN` availability leaves the ramp.
- The result is its own series per regulation service, `fcas_series_name("fcas_agc_ramp_rate", service)`, written by `_set_agc_ramp_rates!` in `nem_system` and skipped when the unit has no availability for that side. It is distinct from the energy ramp series, which keep the lesser of bid and telemetry. For a `ControllableLoad` the raise side reads the lower availability and the ramp-up rate, and the lower side the raise availability and the ramp-down rate. Trapezium scaling and joint ramping both read this one series.

## Departure from AEMO and nempy

- The derived rate is a lower bound on the telemetered rate, so joint ramping can be tighter than NEMDE's. It is never below `RAMPUPRATE`; where `RAMPUPRATE` is 0 (for example STAN units bidding `ROCDOWN = 0`) the derived rate now applies scaling and a joint row where the old rate applied neither.
- nempy takes the rate from the XML `SCADARampUpRate`/`SCADARampDnRate`; this run reads XML for validation only.
- Known gap: availability 0 with a bid and a positive ramp keeps the ramp as the rate; the cause is unknown.

## Why

- Published regulation availability equals `min(bid MAXAVAIL, SCADA rate / 12)`: on case files it matched in 758 of 758 raise and 765 of 765 lower unit-intervals, and `RAMPUPRATE = min(bid, SCADA)` in 2458 of 2458. So the availability carries the telemetered rate and the per-side regulation cap is exact.
