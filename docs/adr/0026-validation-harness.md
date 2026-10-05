# 0026. Validation harness

## Status

Accepted

## Context

`replicate_interval` solves one interval. Judging fidelity needs a fixed, stratified set of
intervals, one tidy result table and distributions per metric, not single means. A month has
8,640 intervals; measured on 2026-06-04, one interval costs about 22 s to build the `System`
and 13 s to build and solve the model (35 s, so a full month is about 84 h), plus about 3 minutes
of compilation in a fresh process.

## Decision

- **Sample, not every interval.** `validation_sample` draws a seeded list round-robin over
  strata (intervention, violated constraint, FCAS spike, each region's price extremes, no binding
  network constraint, binding, ordinary), using published data only. The list is committed
  (`scripts/validation_sample_2026-06.csv`) so runs are comparable. June 2026 has no
  `INTERVENTION = 1` rows, so that stratum is empty there.
- **One System per interval.** Sharing one `System` over a multi-interval range was tried
  (`transform_single_time_series!` over a longer range) and fails in PSY with "forecast count 7
  does not match system count 1", so it is not a small change and was not pursued.
- **Tidy table.** `(interval, stratum, metric_family, key, ours, published, gap)` with
  `gap = ours - published`; a failed interval is a `failure` row and the run continues.
  Families: `regional_rop`, `fcas_rop`, `interconnector_flow`, `interconnector_loss`,
  `dispatch_mw`.
- **Complementary slackness on AEMO's own solution.** Bands offered below `RRP x MLF` should
  be cleared and bands above uncleared, after clipping to availability, UIGF and the ramp
  window. It needs no solve, so it covers the whole month, but it must run one day at a time:
  a single month-wide join of dispatch, bids and prices exhausted memory and disk. A day takes
  1 to 4 s; the month 28 s at 1.6 GB resident. Minimum load, FCAS co-optimisation and storage
  load offers are not modelled in the bracket, so violations include units held by those, not
  only by network constraints.
- **Tolerances.** `VALIDATION_TOLERANCES` are placeholders (1 $/MWh, 1 MW, 5 MW for flows).
  They are to be replaced by a reference solver's own error against the oracle.
- **Real-data runs** cap DuckDB at 3 GB and two threads and spill to a scratch disk.

## Consequences

Binding-set matching and the reference-solver layers are not part of this harness.
