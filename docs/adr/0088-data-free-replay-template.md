# 0088. Data-free replay template

Amended by [0090](0090-template-is-the-replay-scope.md): `template_nemde` takes no arguments and the `parts` argument is removed.

## Status

Accepted. Supersedes the `replication_template` entry point and its public API in
[0025](0025-replication-pipeline.md). The other decisions of 0025 remain in force.

## Context

`replication_template` took the system, database, interval and Market Price Cap, and built the
formulations from the data it read. Its per-interval inputs made the template depend on the
replay range, so a template could not be built once and reused. The replay also had no record of
what it left out: components the template could not model stayed available, and an interval range
that excluded them had no uniform way to say so.

## Decision

- **Type-level template.** `template_nemde(parts = REPLICATION_PARTS)` builds a `PSI.ProblemTemplate`
  from its arguments alone. Each family in `parts` selects formulations by type: `NEMReplayDispatch`
  for each type of `NEM_DISPATCH_DEVICE_TYPES`, `FCASMarket` per `FCASService`, `LinearFactorLimit`
  per `GenericConstraint`, `TieBreakMarket` for `EnergyTieBreak`, and `NEMInterconnectorLoss` per
  `PSY.AreaInterchange`. No system, database, interval or price is passed.
- **Service models expand over available components.** A service model is keyed by its type, with an
  empty name. PSI expands each type-level service model over the components of the system that are
  available when it builds, so an unavailable service generates no formulation.
- **`available = false` means left out of this replay.**
  `exclude_unmodeled_services!(sys, template; parts, exclude_constraints)` sets unavailable the
  components that the replay of `parts` cannot model, and returns one record per `GenericConstraint`
  left out. Each call first sets available again the components the previous call on the same system
  disabled, which it records in the system ext, and then computes its own exclusions. Components
  unavailable in the input are never re-enabled. Storage-only FCAS services are excluded only without
  `:batteries`.
- **Pre-build checks.** `check_template_against_sys(template, sys; parts)` runs after the exclusions
  and before the model is built. It verifies the inputs of `parts`, that every dispatch participant
  has a device model, the tie-break scales, and that each available `GenericConstraint` can be built.
  It throws naming the first failed check.
- **One Market Price Cap, resolved in `replication_decision_model`.** The model resolves the cap once,
  from the explicit `market_price_cap` or the cap published for `initial_time`. It writes that cap to
  both the balance slack cost of the network model and the settings ext. The settings ext is the only
  route by which the construct methods of the penalty formulations see the cap.

## Consequences

- A raw `PSI.DecisionModel(template_nemde(), sys)` prices the balance slacks at PSI's default slack
  cost. Only `replication_decision_model` prices them at the Market Price Cap.
- An FCAS service or tie-break service that is unavailable in the input is not modeled. The skipped
  report lists only the `GenericConstraint`s that the exclusions set, so it does not list these services.
- A template can be built once per `parts` and reused across intervals and systems, because it reads
  no data. Each replay range still needs its own check and exclusion pass.
- `replication_template` and `_constrained_system` are removed; callers use `template_nemde`,
  `exclude_unmodeled_services!`, `check_template_against_sys` and `replication_decision_model`.
