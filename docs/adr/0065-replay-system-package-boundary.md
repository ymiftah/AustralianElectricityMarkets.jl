# 0065. AEM owns database-backed system construction

## Status

Accepted. Supersedes the package ownership and replay entry points in
[0025](0025-replication-pipeline.md) and [0061](0061-replay-core-stock-simulation.md).
The recurrent PSI execution strategy is retained.

## Context

The replay runner mixed database reads, system construction, model preparation, PSI execution
and published-result comparison inside AEMSim. Moving only the system constructor would leave
cache access in coverage checks and the range runner, making the package boundary ambiguous.

## Decision

- AEM owns cache readers and populated system construction. `ReplayNetworkConfiguration` follows
  the existing `nem_system(db, configuration; ...)` type-dispatch interface. Its constructor owns
  source-data coverage checks and the database-backed setters previously called by the runner.
- AEMSim accepts an existing `PSY.System`. `prepare_replication!` derives model-specific FCAS
  parameters, tie-break scales and forecast windows from attached data. These operations require
  PSI helpers but no database access, so they remain in AEMSim.
- `replication_simulation` validates the prepared system and returns an unbuilt `PSI.Simulation`.
  Callers use PSI's build, execute and results APIs. `replication_results` extracts solved output
  tables and violations from those results and system metadata. Formulation selection continues
  through PSI types and dispatch.
- Top-level repository scripts own chunk selection, AEM system reconstruction, cache reads for
  published outcomes, comparison joins and reporting. They preserve the existing trading-day,
  financial-year and optional period boundaries so static inputs refresh through AEM.
- AEMSim imports domain types and attached-data accessors explicitly, exports no database-taking
  replay entry point, and has no DuckDB runtime dependency. DuckDB remains a fixture dependency
  of tests. Reader assembly tests live in AEM; script workflow tests live outside the package
  and run in the Simulations CI environment.

## Model behaviour

This is an ownership refactor. Dispatch, FCAS, loss, energy-limit, storage and offer-band
formulations are unchanged, including their bounds, penalty factors, units and initial-condition
semantics. The same AEM setters populate the same source data in the same order. Preparing a
system uses the existing effective-offer and tie-break calculations and one-interval windows.
There is no new departure from AEMO's model.

Published-result lookup is confined to comparison scripts. Existing published initial MW
inputs retain their role as interval-start metering. Optional post-dispatch interconnector
flow limits retain their diagnostic opt-in and are not used by default for replay validation.

## Consequences and validation

A caller can construct a system through AEM, close the database connection, then prepare, build
and execute through AEMSim and PSI. Memory-backed and disk-backed lifecycle regressions cover
this boundary. AEM constructor regressions cover malformed offers, missing demand, intervention
selection and optional flow limits. Existing toy-system recurrent solves and the relocated
script comparisons retain their coverage, including chunk splitting and missing solved values.

The API change is intentional: no database-taking forwarding shim remains in AEMSim. This
change is stacked above #217 and does not rewrite #213 through #217.
