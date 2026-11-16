# 0090 The template is the replay scope

## Status

Accepted. Absorbs the removed ADR 0088 (data-free replay template). The replay interface is in [0092](0092-psi-shaped-replay-interface.md) and [0101](0101-aem-writes-aemsim-reads.md).

## What

- `template_nemde(; exclude_constraints)` builds a `PSI.ProblemTemplate` from type-level arguments only; no system, database, interval or price. It models `NEMReplayDispatch` for each type of `NEM_DISPATCH_DEVICE_TYPES` (batteries included), `NEMInterconnectorLoss` for `PSY.AreaInterchange`, an `FCASMarket` per `FCASService`, the aggregated `LinearFactorLimit` for `GenericConstraint` and `TieBreakMarket` for `EnergyTieBreak`.
- The template is the scope. There is no list of optional parts: a replay that models less builds its own `PSI.ProblemTemplate`.
- Checks read the scope from the template (`_has_device_model`, `_has_service_model`): `check_template_against_sys`, `check_fcas_services`, the replay inputs check and `replay_skipped_constraints`.
- Every dispatch participant type of the system must have a device model in the template, batteries included; otherwise `check_template_against_sys` throws.
- A template without an FCAS service model or an `AreaInterchange` model records the generic constraints that depend on them as skipped. Any other unbuildable constraint throws.
- A raw `DecisionModel(template_nemde(), sys)` prices balance slacks at PSI's default slack cost; only `DecisionModel{NEMDispatchProblem}` prices them at the Market Price Cap ([0085](0085-build-time-market-price-cap.md)).

## Why

- A data-free template can be built once and reused across intervals and systems; per-interval inputs belong to AEM's system.
- A separate parts list was a second source of truth beside the template and spread carve-outs (storage-only FCAS, tie-break scales without batteries) across every check. No production caller used a subset.
- A template without a battery model fails the check while the system has available batteries. Setting them unavailable is not enough, because a generic constraint with a battery term stays unbuildable and an FCAS service whose only contributors are batteries leaves PSI with an empty service; such a replay removes the batteries and those constraints and services from the system.
