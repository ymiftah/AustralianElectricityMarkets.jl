# 0025. Single-interval replication pipeline

## Status

Accepted

## Context

Phase 2 builds a `System` with `ConstrainedNetworkConfiguration` and a template of NEM
formulations. Checking them against AEMO's published outcome for one dispatch interval needs a
reproducible entry point that wires both together and reads the published results.

## Decision

- **Two-interval window.** `replication_system` builds the interval and the one after it. PSY
  rejects a single-point `Deterministic` forecast ("Forecast arrays must have a length of at
  least 2"), so a one-interval range cannot be built. Only the first interval is reported, and
  the cache must hold data one interval past `settlement_date`.
- **ROP, not RRP, for energy prices.** The solved regional balance dual is the price before
  scaling, capping or an administered price, which is what `ROP` is. `RRP` differs from `ROP`
  only when `APCFLAG != 0`, so the comparison reports published `ROP` against solved and carries
  `RRP` alongside.
- **Lives in `src/`.** The pipeline is in `AustralianElectricityMarketsSimulations/src/replication/`
  rather than a separate scripts project, so it is tested on the mock hive in CI and DuckDB
  reads stay in `replication/inputs.jl`. A thin script in `scripts/` prints the comparison.
- **Public API.** `replication_system`, `replication_template`, `replicate_interval` and
  `read_published_interval` are exported: they are the supported way to run one interval, and
  validation tooling outside the package builds on them.
- **Unavailable components in constraints.** A generic constraint term on an unavailable device
  or interconnector contributes zero, as FCAS terms already do, because PSI creates variables
  only for available components.
- **Comparison keeps every published row.** Solved values are `missing` where the model has no
  value (for example an unavailable unit), instead of rows disappearing in an inner join.
