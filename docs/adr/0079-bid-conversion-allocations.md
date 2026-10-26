# 0079. Construct final bid curves once

## Status

Accepted.

## Context

After the market-input query improvements, the warm full-day system build still
allocated approximately 4.53 GB. A fresh profile of the 22 January 2026 input found
repeated work in bid conversion. The original energy conversion stage allocated
281.5 MB for 156,060 rows; FCAS conversion allocated 1.770 GB for 456,042 rows.
These are Julia allocations for conversion, excluding the data reads and DuckDB
native memory. Sampled allocation sites include numeric field access, curve arrays
and diagnostic context formatting; sampled sizes are not exact allocation shares.

Energy conversion constructed an unreferred curve and then another with its
loss-adjusted prices. FCAS conversion constructed a native-MW curve and then another
with per-unit breakpoints. Valid FCAS rows also formatted a full diagnostic context
that was discarded by validation.

## Decision

Construct each final energy curve with its existing direction-specific loss factor
and cent rounding. Construct each final FCAS curve with its existing system-base
quantity conversion. Keep cumulative quantities in their original order before
base conversion, and validate raw breakpoints so that rounding cannot hide a decrease.
All-band extraction directly selects owned price and quantity vectors; other cases
retain the original filtering behavior, including mismatched-band errors.

The energy setter continues to validate all input rows before filtering units absent
from the system. Only modeled units require a loss factor. Stored coordinate vectors
remain independently owned and compatible with file-backed time-series storage.

Allow the FCAS trapezium validator to accept a context function evaluated only on
failure. Existing string callers remain supported. Retain the validation predicate,
original-MW diagnostic values, timestamp context and error text. Missing ramp rates
remain NaN in the packed wire representation.

## Market correctness

No bounds, constraint coefficients, cost values, factor selection or timing rules
change. The refactoring retains the existing division of energy prices by their
connection-point loss factor and cent rounding, and does not refer FCAS prices.

The bid-price relationship and separate directional loss factors are described in
AEMO's [Treatment of Loss Factors in the National Electricity Market, sections 13
and 14](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2016/treatment_of_loss_factors_in_the_nem.pdf).
That document is used for its price relationship, not its historical interval or
settlement conventions. FCAS capability remains the trapezium in AEMO's
[FCAS Model in NEMDE, section 2](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
There is no departure from either rule in this change.

## Validation

Focused regressions compare with the original conversion for generation, load and
bidirectional rows, zero-width and empty bands, cent rounding, missing ramps, per-unit
scaling and independently owned vectors. They also cover required loss factors,
unmodeled invalid rows, original-MW error context, deferred callback evaluation and
raw decreases hidden by floating-point underflow. The 256 focused checks pass.

Original source snapshots, full-day conversion fingerprints, paired warm timings,
allocation profiles and full-suite logs are retained under
`scripts/results/bid_conversion_20261026/`.

Three quiet warmed system builds per implementation measured mean construction time
of 18.420 seconds for commit 0438526 and 17.818 seconds for the updated
implementation, an observed 3.3% reduction. Mean Julia allocations fell from
4,526,402,875 to 3,640,301,589 bytes, a 19.6% reduction. All six
measured system builds reported zero compilation time. Native DuckDB allocation and
solve time are excluded. Cumulative process RSS cannot attribute peak resident memory
to either implementation.

Energy conversion allocations fell from 281.5 MB to 136.6 MB; FCAS conversion
fell from 1.770 GB to 1.031 GB. Conversion-stage timing overlaps tests in the
baseline, so only stage allocation figures are compared. All 156,060 energy curves
and 456,042 FCAS curves and packed trapeziums matched bit-for-bit. The replay input
window includes one extra five-minute interval after the trading day. Component
counts are unchanged. The full root suite passed 1,723 checks and the full
Simulations suite passed 1,925; Runic and configured hooks also passed.
