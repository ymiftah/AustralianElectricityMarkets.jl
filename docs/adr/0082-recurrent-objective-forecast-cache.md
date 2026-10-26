# 0082. Recurrent objective updates share the model forecast cache

## Status

Accepted.

## Context

A disk-backed replay of the 2026-01-06 trading day spent 6.91 hours in parameter updates
across 287 recurrent transitions, averaging 86.7 seconds per transition. The run used Julia
1.13.2 with `-O0`, HiGHS, a relative MIP gap of `1e-8`, and file-backed system time series.
Execution-recorder timestamp differences attributed approximately 3.47 hours to FCAS band
price updates and 2.72 hours to generic-constraint slack cost updates. These differences
locate expensive update families; they are not instruction-level profiles.

Both update families called a build-time forecast reader directly. With disk-backed data,
that path repeatedly looked up metadata, opened the HDF5 store and deserialised forecast
windows rather than using the decision model's existing time-series cache. Generic slack
cost updates also searched every service model to find the one matching each constraint.
With 1,207 generic constraints, this produced quadratic service-model lookup work.

## Decision

Use the pinned PowerSimulations decision model's `get_time_series_values!` API during
recurrent FCAS price and generic-constraint invocation reads. Preserve direct container
reads during construction and preserve the model's cache-disabled behavior. The existing
PSI forecast cache owns its entries and their lifetime; there is no global or system cache.
Read the current interval at the existing horizon and ignore scaling factors as before.

Retrieve a generic constraint's service model by `(GenericConstraint, name)` through
`PSI.get_model`. Keep its configured attributes, including any explicit Market Price Cap.
Retain the existing objective-reset and re-pricing lifecycle at each interval.

## Market semantics

No variable bound, constraint equation, CVP factor or bid price changes. The two affected
cost terms remain:

- FCAS offer band price times cleared band MW times the interval duration in hours.
  AEMO's [Guide to Frequency Control Ancillary Services](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/ancillary_services/guide-to-frequency-control-ancillary-services.pdf),
  version 4.0, effective 17 September 2025, section 3.3, pages 7-9, describes enablement from
  submitted FCAS bids and co-optimisation of energy and FCAS costs.
- Generic-constraint slack MW times its CVP factor times the applicable MPC times the
  interval duration in hours, masked by the constraint's invocation series.
  AEMO's [Schedule of Constraint Violation Penalty Factors](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf),
  version 8.0, effective 2 December 2025, section 1, page 3, defines the factor, MPC and
  violation-amount relationship. Existing per-unit conversion and interval scaling remain.

There is no new departure from AEMO's formulation.

## Verification

The disk-backed regression changes both an FCAS price and an invocation mask at the second
interval. After warming the cache, it temporarily makes the HDF5 file unavailable and checks
that objective updates still use the correct second-interval values. The cache-disabled
case reads the same values from the available store. A service-specific MPC override is
checked before and after the invocation mask changes.

The existing recurrent-simulation tests compare updated dispatch, FCAS outcomes, objectives
and duals against standalone interval solves. Real-data performance checks use identical
inputs, solver settings and Julia optimisation levels, with update and solve time reported
separately. Short-window measurements are not full-day throughput guarantees.
