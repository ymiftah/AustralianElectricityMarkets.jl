# 0018 FCAS trapezium scaling (AEMO *FCAS Model in NEMDE* §4)

## Status

Accepted; the §4.2 ramp input is amended by [0087](0087-agc-ramp-rate-from-mmsdm.md), and AEM applies the scaling when it writes effective offers ([0101](0101-aem-writes-aemsim-reads.md)).

## What

NEMDE shrinks the bid trapezium before optimising. Each bound is replaced only when the input is more restrictive, and the paired breakpoint slides to keep the bid's own slope angle:

- §4.1, `RAISEREG`/`LOWERREG` only: telemetered AGC enablement limits replace `EnablementMin`/`EnablementMax`. No scaling if the limit is zero or absent.
- §4.2, regulation only: the AGC ramp rate times the dispatch interval replaces `MaxAvail`. No scaling if the rate is zero or absent.
- §4.3, every service on a semi-scheduled unit: UIGF replaces `EnablementMax`. No zero exemption: a UIGF of `0.0` is a real forecast of no output.
- A contingency bid from a scheduled unit is never scaled.

## How

- `scale_fcas_trapezium(trap; agc_enablement_min, agc_enablement_max, agc_max_avail, uigf, is_regulation)` is the pure arithmetic. It recomputes breakpoints from the bid's own slope coefficients and the final limits, which equals applying the steps in sequence.
- Breakpoints are never clamped. A squeezed trapezium may have `HighBreakpoint < LowBreakpoint` or `EnablementMax < EnablementMin`; clamping flattens the slopes and enables FCAS NEMDE would not. The §5 `EnablementMax ≥ EnablementMin` gate disables the empty case.
- Inputs come from `DISPATCHLOAD` (`RAISEREGENABLEMENTMIN/MAX`, `LOWERREGENABLEMENTMIN/MAX`, documented as the more restrictive of bid and telemetered, so idempotent with the min/max) and `AGCSTATUS`. Ramp rate and UIGF as in the replay inputs; a missing interval is `NaN` and means "absent" for that interval only.
- §4.2 uses the model's interval length, not the `date_range` step.
- Semi-scheduled means `DUDETAILSUMMARY.SCHEDULE_TYPE = 'SEMI-SCHEDULED'` at the interval (`read_uigf`), not a non-null `DISPATCHLOAD.UIGF`: scheduled and non-scheduled units publish `UIGF = 0`, which would clamp every scheduled unit's `EnablementMax` to zero.
- One telemetered enablement pair per DUID and service scales both sides of a two-sided battery. An `AGCSTATUS = 0` row can invert the window; it is applied as AEMO's arithmetic gives, then §5 disables the offer (and the AGC-status check does regardless).

## Departures

- **Zero/absent guard.** nempy treats `AGC value > 0` as present. We follow AEMO's "zero or absent" with `!isnothing(x) && !iszero(x)`, because a negative telemetered `EnablementMin` (for example a battery's `-6.0`) is ordinary for a `PSY.Storage` regulation bid.
- **§4.2 input.** Not `*REGAVAILABILITY` alone and not the SCADA rate (not in MMSDM): the rate is derived as in [0087](0087-agc-ramp-rate-from-mmsdm.md). nempy reads `RAMPUPRATE`/`RAMPDOWNRATE`.

## Why

- Without scaling, a plant whose AGC telemetry or forecast is tighter than its bid is modelled as more capable than NEMDE dispatched it.
- nempy (`_scaling_for_agc_enablement_limits`, `_scaling_for_agc_ramp_rates`) matches this arithmetic and column choice, except the guard above.
