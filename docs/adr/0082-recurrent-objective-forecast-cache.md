# 0082. Recurrent objective updates share bounded model caches

## Status

Accepted.

## Context

Recurrent FCAS and generic-constraint objective reads bypassed PSI's forecast cache.
Energy slopes also read static bids directly. Disk-backed replays repeatedly opened and
closed HDF5 files, while generic slack updates searched all service models for each constraint.

IS estimates a PiecewiseStepData row with shallow `sizeof`, excluding its coordinate vectors.
Its default nominal 1 MiB cache can therefore retain 65,536 rows per series, often the whole
remaining history. The nominal size is not a retained-memory bound or a model-wide budget.

## Decision

Use the model-owned IS cache for recurrent reads and keep direct container reads during
construction. Bound structured energy and FCAS bid caches to 24 rows/windows per series,
independently of the results-write buffer. Respect disabled caching and keep native scaling,
parameter unwrapping, objective conversion and invocation-dependent re-pricing.

Cache static energy slopes only for single-period NEM models with matching interval and
series resolution. Other formulations, horizons and feature-qualified keys retain their native
reader. Retrieve generic service models by their keyed name and reuse built FCAS contributors.

## Alternatives

- Direct reads preserve arbitrary access but repeat costly file operations on every interval.
- Whole-history caching reduces refills but increases retained memory and first-update work.
- A separate global cache adds ownership and invalidation rules that the model already supplies.

## Consequences

The bound limits stored structured history, not total model RSS. Memory still scales with
series count, horizon and curve payload. Refills occur during long runs and must be measured
alongside warm-up and steady-state execution. File-backed storage remains file-backed.

IS caches accept repeated timestamps and sequential advancement only. Clear the model cache
before restarting a sequence; out-of-order reads require the native uncached path. Cache state
belongs to the decision model, and private PSI/IS dispatch contracts must be checked on pin changes.

No bounds, equations or cost terms change. FCAS costs retain offered price times cleared MW
times interval hours, as described in AEMO's [FCAS guide](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/ancillary_services/guide-to-frequency-control-ancillary-services.pdf),
v4, section 3.3. Generic slack penalties retain CVP times MPC times violation amount and invocation,
as in AEMO's [CVP schedule](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf),
v8, section 1. Energy bid referral and directional loss factors retain the relationship in
AEMO's [Treatment of Loss Factors](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2016/treatment_of_loss_factors_in_the_nem.pdf),
sections 13-14; its historical settlement intervals are not adopted. There is no new market departure.
