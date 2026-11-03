# 0090. The template is the replay scope

## Status

Accepted. Amends [0088](0088-data-free-replay-template.md): `template_nemde` takes no arguments, and
the `parts` argument of the replay checks and scripts is removed. The other decisions of 0088 remain
in force.

## Context

`template_nemde(parts)` selected the replay's optional families through `REPLICATION_PARTS`:
batteries, FCAS, losses, tie-breaks and generic constraints. Every check and script then repeated the
gates on `parts`, so the carve-outs spread across `exclude_unmodeled_services!`,
`check_template_against_sys`, `check_fcas_services`, the replay inputs check and the replay scripts:
the storage-only FCAS exclusion, the tie-break scale check for templates without batteries, and the
`excluded_device_types` keyword. No production caller used a subset of the parts. The replay workflow,
the simulation runner and the NEMDE tutorial all passed the full set. The parts were a second source of
truth beside the `PSI.ProblemTemplate`, which already states what the model builds.

## Decision

- **The template is the scope.** `template_nemde()` takes no arguments and lists every model
  explicitly. A consumer that replays less builds its own `PSI.ProblemTemplate` and passes it as
  `template`.
- **Checks read the scope from the template.** `_has_device_model` and `_has_service_model` decide
  whether a family applies. `exclude_unmodeled_services!`, `check_template_against_sys`,
  `check_fcas_services`, the replay inputs check and the results reader take the template, and none
  takes a parts argument.
- **Every dispatch participant must be modeled.** A participant type with no device model fails
  `check_template_against_sys`. Batteries have no carve-out.
- **Tolerated left-outs.** A template without an FCAS service model or without an `AreaInterchange`
  model still records the generic constraints that depend on them as skipped. Any other unbuildable
  constraint throws.
- **Removed.** `REPLICATION_PARTS`, `check_replication_parts`, the storage-only FCAS exclusion, the
  tie-break scale check for templates without batteries, and the `excluded_device_types` keyword of
  `check_fcas_services`.

## Consequences

- A template without a battery model fails `check_template_against_sys` while `sys` has available
  batteries. Setting the batteries unavailable is not enough on its own: a generic constraint with a
  battery term is still unbuildable, and an FCAS service whose only contributors are batteries leaves
  PSI with an empty service. A replay without batteries removes them, and those constraints and
  services, from `sys`.
- A battery-only FCAS market is no longer excluded. It is built under the FCAS model, so its battery
  contributors must be modeled.
- Every replay template models the batteries, so the replay tests that formerly omitted them now
  exercise them.
