# 0083 Time-series storage stays with PSY and IS

## Status

Accepted.

## What

- AEM reads and writes time series only through PSY/IS and their native caches. It has no HDF5 deserializers, file-handle inspection or storage-ownership code.
- Every environment that builds systems or runs simulations requires HDF5 0.17.5 and pins the official fixed release-branch revision through `[sources]` until a tagged release satisfies that lower bound.
- `AustralianElectricityMarketsSimulations/test/real_data/benchmark_store_reads.jl` is a local diagnostic outside CI; it compares ordinary PSY reads with PSY's bulk-open API.

## How

- The root and Simulations `Project.toml` carry `HDF5 = "0.17.5"` in `[compat]` and the pinned revision in `[sources]`; remove the pin once a tag is released.
- The batch runner runs each trading day in a fresh Julia process, which bounds native handle lifetimes at the cost of repeated package loading.

## Why

- HDF5.jl 0.17.4 leaks a datatype ID per file close (`_check_invalid`), which survives GC and made repeated system builds slower and slower. The fix is upstream HDF5.jl PR 1270, in release-0.17 but not yet tagged when pinned.
- Local storage code would duplicate PSY/IS and add an ownership rule to maintain.
