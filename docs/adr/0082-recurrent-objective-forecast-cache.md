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

### Controlled real-data pilot

`test/real_data/benchmark_updates.jl` measures 2026-01-06 interval ends 04:05, 04:10 and
04:15 AEST. Both revisions used Julia 1.13.2 with `-O1`, PSI 0.38.4 at its pinned revision,
HiGHS.jl 1.26.1, one solver thread, relative MIP gap `1e-8`, absolute gap `1e-10`, disk-backed
forecasts and 2,800 parameter containers. The baseline formulation files were unchanged from
`v0.2` at `feb3b5f`; the fixed implementation was `408acf4`. Each result records SHA-256
hashes of the three formulation files. Other local test work ran concurrently, so the
wall-clock observations are a pilot rather than a stable throughput distribution.

| Update | Baseline seconds | Cached/keyed seconds |
| --- | ---: | ---: |
| 04:05, warm-up | 102.0068 | 125.5078 |
| 04:10 | 14.6142 | 2.0710 |
| 04:15 | 7.8590 | 1.7312 |
| Mean excluding warm-up | 11.2366 | 1.9011 |

The warmed mean improved by 5.91 times. Cache construction moved work into the first update,
which took longer. Construction, solves, exports and audit work are excluded from update
times. The baseline and fixed pilot objectives matched exactly at all three intervals.
For each interval, all 42,883 exported variable cells, their objective coefficients, and
all 4,243 stored pricing-dual cells also matched exactly; no duplicate export keys occurred.

The exported point omits 29,951 model variables outside the registered decision-variable
containers, so the harness reported incomplete primal-audit coverage. These comparisons
establish update equivalence for this pilot, not independent full-model feasibility or
market fidelity. A complete trading day was not re-run after the fix.

Local raw pilot folders are `/tmp/aem-update-before-complete-o1` and
`/tmp/aem-update-after-complete-o1`; the comparison summary is
`/tmp/aem-update-comparison.json`. Earlier construction/profile attempts and failed exporter
attempts are excluded from the table. The complete Simulations suite passed 2,117 checks;
pre-commit checks and independent source review passed.
