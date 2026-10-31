# 0080. Reduce conversion and build-local lookup allocations

## Status

Accepted.

## Context

After constructing final bid curves once, full-day system construction still allocated
approximately 3.64 GB of Julia memory. A new allocation sample of that revision found
numeric FCAS field access as the largest sampled conversion site. The setter also copied
each service's raw columns and then materialised directional subsets. Coverage validation
and setters independently read several identical inputs. Generic-constraint construction
resolved component names repeatedly while building terms and its diagnostic pass.

## Decision

Specialise FCAS numeric extraction on the field symbol using `Val`, retaining the existing
symbol entry point and missing-field error. Construct only the routing columns and final
curve/trapezium columns for each FCAS service. Directional groups view this smaller table;
attached time series still collect independent plain vectors required by file-backed storage.
Every input row of each recognised service is converted and validated before routing.

Keep public database-backed setters. Private frame-based helpers allow replay construction
to share its demand and dispatch reads between coverage checks and attachment. Regional
construction returns its already-read unit frame to the private replay constructor. Constraint
construction and fixed-loading attachment share one raw fixed-loading read. There is no global
market-data cache. Energy coverage continues to read period offers independently from the price
join, so an incomplete price cache cannot remove a required participant from coverage checks.

Each generic constraint receives a lazy component resolver for its model-construction stage.
The first lookup delegates to PowerSystems, preserving missing and ambiguous-name behavior;
subsequent requests for the same type and name reuse the result. The resolver is discarded
before another construction phase. Forecast values and metadata handles are not cached across
intervals. Sharing PSI-owned forecast registration handles remains a separate investigation.

Add a PrecompileTools workload using one in-memory bus and generator and two synthetic energy
offers. It exercises conversion, loss-factor referral, attachment and offer access without
opening DuckDB, reading a user cache, accessing the network or writing an HDF5 store. This
trades a larger package cache and longer one-time precompilation for lower first-use latency.
It makes no claim to precompile a complete dispatch model.

## Market correctness

There are no new bounds, cost terms, coefficients or market rules. Direction routing, raw-MW
trapezium validation, per-unit scaling, cent rounding and independently owned stored curves
are retained. Shared reads retain the same date range, effective-date selection, resolution
and intervention. Unit rows are not mutated during component construction.

AEMO's [FCAS Model in NEMDE, version 3.0, section 2, pages 6 to 11](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf)
defines the ten bands and trapezium fields. The [Electricity Data Model Report](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/),
BIDPEROFFER_D, DISPATCHLOAD and DUDETAILSUMMARY, governs offer direction, intervention and
unit metadata selection. There is no departure from these inputs or rules.

## Verification and measurements

The allocation and timing harness, source snapshots and provenance, regression logs and
precompilation experiment are retained in `scripts/results/build_reuse_20261026/`.
The paired full-day build uses 22 January 2026, intervention 0, five-minute inputs, no published
interval flow-limit replay and the pinned PowerSimulations revision. Julia allocated bytes
exclude native DuckDB memory. No dispatch intervals are solved by the performance benchmark.

The full root suite passes 2,022 checks; the full Simulations suite passes 1,932. Targeted
coverage includes inferred FCAS field extraction, numeric/missing-field diagnostics,
directional row order and unchanged raw inputs, independent database-backed versus shared-input
setter results, intervention selection, incomplete inputs, file-backed storage, System JSON
round trips, missing components and cross-type name ambiguity. Independent source and domain
review found no outstanding issue. Runic and configured pre-commit hooks pass.

A separate isolated component-lookup benchmark includes constructing 100 local resolvers with
eight lookup passes per resolver. Median time falls from 0.057623 to 0.009659 seconds; Julia
allocations fall from 9,453,440 to 1,687,040 bytes. These are lookup results, not whole-model
speedups.

A separate two-process-per-variant synthetic precompile experiment measures first energy-offer
conversion at a mean 3.903 seconds before the workload and 0.091 seconds afterwards. Its
one-time root package precompilation grows from 7.683 to 20.303 seconds, and the native cache
from approximately 2.9 to 21 MiB. This experiment uses warm dependency caches and measures the
small synthetic offer path, excluding a complete NEM system, PSI build and dispatch solves.

The paired full-day comparison against commit `5eb671e` excludes two warm-up builds and
measures three builds per implementation in the same process. All 30 measured phase/conversion
samples record zero compilation, with no overlapping test runs. Mean system construction falls
from 17.864 to 15.686 seconds (12.2% less time), and Julia allocations from 3.641 to 3.054 GB
(16.1% fewer bytes). Optimisation/simulation construction falls from 4.312 to 4.020 seconds,
and allocations from 909.6 to 864.8 MB. Forecast preparation and pre-flight are essentially
unchanged. The sum of the four construction phases falls from 25.620 to 23.187 seconds and
6.642 to 6.011 GB, approximately 9.5% less time and allocated memory. This sum excludes manual
GC, fingerprints and harness overhead between phases.

The FCAS conversion harness, including identical frame copies, falls from 1.091 to 0.653 GB
and 0.861 to 0.325 seconds. All values of 13,253 attached series across 2,215 components have
identical fingerprints. Every built optimisation retains 81,498 variables and 123,898
constraints. The saved input window includes one extra five-minute input interval after the
288-interval trading day. These are observed warm-build results, not dispatch solve speedups
or native-memory/peak-RSS reductions.
