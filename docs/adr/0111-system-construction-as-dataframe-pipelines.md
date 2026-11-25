# 0111 System construction reads as DataFrame pipelines

## Status

Accepted. Extends [0110](0110-readable-reader-queries.md) from the readers to system construction
and the NEMDE input stage.

## What

- A function that builds part of a `System` shapes its data with DataFrames.jl verbs (`subset`,
  `select`, `transform`, `groupby` / `combine`, `leftjoin` / `semijoin` / `antijoin` / `crossjoin`,
  `stack` / `unstack`) under `@chain`, then runs one plain loop of PSY mutations. No index `Dict`s
  keyed by timestamp, no per-stamp loops that look values up, no one-caller helper stacks.
- Joins that feed a positional series pass `order = :left`: DataFrames does not otherwise preserve
  row order.
- Every single time series of a NEMDE System is on one grid. `_set_nemde_inputs!` reads it once
  (`_nemde_grid`) and passes it to every writer, and `_values_on_grid` is the one reader of a bid or
  telemetry field on it. Per-device stamp re-reading and alignment are removed.
- The per-device NEMDE writers (ramps, AGC, state, fast-start, FCAS) stay per-device broadcasts of
  the scalar kernels: each device reads different fields through a different kernel, so a device by
  interval table would carry the same branching plus a `stack` / `unstack`. Writers that group across
  devices (tie-break, loss demand, regional availability, constraints) are DataFrame pipelines.
- `read_offers` is the only offer query; `read_bids` and `read_fcas_bids` select from it and coarsen
  with one `groupby` / `combine` (`_aggregate_offers`). At a coarse resolution the FCAS trapezium
  points come from the bucket's last interval, quantities are means of the present values.

## Why

- Construction is a sequence of tabular derivations; written as pipelines each step reads in one
  place, where the helper stacks spread one derivation over several functions.
- The two coarse-resolution aggregations (SQL in `_massage_bids`, Julia in `_aggregate_offers`)
  disagreed on the trapezium; one aggregation removes the disagreement.
- Cost: validation in MNSP offers and unit conditions runs stage by stage over whole frames, so with
  several faults the first error reported can differ from the device-by-device order. Single-fault
  messages are unchanged.
- Cost: `BIDDAYOFFER` becomes a required table for every energy offer read, since the in-force
  lookup is part of the one query.
