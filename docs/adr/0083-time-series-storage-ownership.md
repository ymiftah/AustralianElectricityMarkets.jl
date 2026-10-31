# 0083. Time-series storage remains owned by PSY and IS

## Status

Accepted.

## Context

Replay profiles include substantial native HDF5 close work. HDF5.jl 0.17.4 leaks a
transient datatype in `_check_invalid`; its finalizer skips release after the parent file
closes. Identical real-data system builds retained 12,735 extra datatype IDs per build,
surviving GC. Warm construction times rose from 37.8 to 71.4 seconds across builds two
and three; testing eager closure reduced these to 15.2 and 17.8 seconds with a constant
239 datatype IDs. These are short-window construction probes, not full-day timings.

The upstream fix is [HDF5.jl PR #1270](https://github.com/JuliaIO/HDF5.jl/pull/1270).
The official `release-0.17` revision `4c4592a397a4e4f6045a56003ca4d038c8eb3a78`
contains it and identifies itself as 0.17.5, which is not yet tagged. Bulk-open reads also
retain group and dataset handles until GC or file close, a separate effect from the
persistent datatype leak.

## Decision

AEM requests time series through PSY/IS and uses their native caches. It does not implement
HDF5 deserializers, inspect file handles or manage nested storage ownership. Require HDF5 0.17.5 and temporarily pin the official fixed release-branch revision in
each environment that constructs systems or runs simulations. Remove the source pin when
a tagged fixed release can satisfy that lower bound.

Keep the standalone `benchmark_store_reads.jl` diagnostic outside CI. It compares ordinary
PSY reads with PSY's supported bulk-open API, using the same file-backed structured series.
The timed batch runner isolates trading days in separate processes to bound resource lifetimes.

## Consequences

Process isolation is a containment measure and repeats package loading and compilation.
The dependency pin prevents persistent datatype accumulation without adding local storage
code. A native-handle regression covers repeated file-backed writes. Whole-day timing and
numerical comparisons remain necessary before claiming a full-run speedup.
