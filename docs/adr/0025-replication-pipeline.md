# 0025 Replication result conventions

## Status

Accepted as to the conventions below. The single-interval pipeline and its entry points (`replication_system`, `replication_template`, `replicate_interval`) are gone: see [0061](0061-replay-core-stock-simulation.md), [0065](0065-replay-system-package-boundary.md) and [0088](0088-data-free-replay-template.md).

## What

- Energy prices compare against published `ROP`, not `RRP`. The solved regional balance dual is the price before scaling, capping or an administered price, which is what `ROP` is; `RRP` differs only when `APCFLAG != 0`.
- A generic constraint term on an unavailable device or interconnector contributes zero (PSI makes variables only for available components), as FCAS terms do ([0024](0024-fcas-terms-in-generic-constraints.md)).
- Comparison keeps every published row: solved values are `missing` where the model has no value (for example an unavailable unit), instead of rows vanishing in an inner join (`compare_intervals`, `comparison_summary` count them as `n_missing`).
