# 0080 Build-local input reuse and the precompile workload

## Status

Accepted

## What

- Public database-backed setters stay. Replay construction shares its demand, dispatch and fixed-loading reads between coverage checks and attachment through private frame-based helpers.
- There is no connection-wide or global market-data SQL cache.
- Each generic constraint gets a lazy component resolver for its construction stage only; the first lookup delegates to PowerSystems (missing and ambiguous-name behaviour unchanged), later lookups of the same type and name reuse it, and it is discarded afterwards.
- `src/precompile.jl` (and the Simulations equivalent) holds a PrecompileTools workload on an in-memory bus, generator and synthetic offers. It opens no DuckDB, reads no user cache, uses no network and writes no HDF5 store.

## Why

- Queries may reference temporary registered tables and consumers mutate returned frames, so a shared cache is unsafe.
- Energy coverage reads period offers independently of the price join, so an incomplete price cache cannot remove a required participant from coverage checks.
- Forecast values and metadata handles are not cached across intervals.
- The workload trades a larger package cache and longer precompilation for lower first-use latency; it does not precompile a full dispatch model.
- No AEMO formulation changes: FCAS direction routing, raw-MW trapezium validation, per-unit scaling and cent rounding are unchanged (AEMO *FCAS Model in NEMDE* v3.0 s2).
