# 0083. Time-series storage remains owned by PSY and IS

## Status

Accepted.

## Context

Replay profiles include substantial native HDF5 close work. Opening a file for a whole
operation is not sufficient evidence of a fix: the local PSY-only repeated-read diagnostic
shows bulk-open reads becoming slower as the number of reads increases. This observation
supports dependency-level investigation but does not establish a leak or its root cause.

## Decision

AEM requests time series through PSY/IS and uses their native caches. It does not implement
HDF5 deserializers, inspect file handles or manage nested storage ownership. A storage-lifetime
fix belongs in the owning dependency, with its own reproducer and regression tests.

Keep the standalone `benchmark_store_reads.jl` diagnostic outside CI. It compares ordinary
PSY reads with PSY's supported bulk-open API, using the same file-backed structured series.
The timed batch runner isolates trading days in separate processes to bound resource lifetimes.

## Consequences

Process isolation is a containment measure and repeats package loading and compilation.
It does not fix construction-time storage overhead. The current changes make no claim of a
whole-day storage speedup; representative timing and numerical comparisons remain necessary.
