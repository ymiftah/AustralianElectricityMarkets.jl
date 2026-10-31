# 0071. Penalty and band costs stay objective-only

## Status

Accepted.

## Context

PowerSimulations writes per-device cost expressions to results: market-bid (energy offer) costs
enter `ProductionCostExpression` and its generic proportional costs `FixedCostExpression`. AEMSim
prices its violation-penalty slacks (device rows, interconnector flow, area balance, FCAS and
generic constraints) and FCAS and MNSP offer bands itself, adding them to the objective only. A
review against PSI's patterns noted that summing `ProductionCostExpression` therefore misses these
costs whenever a penalty binds or FCAS or MNSP clears.

## Decision

Keep these costs objective-only and say so in the formulation docstrings. Adding device penalty
terms to a per-device expression would need their own step-update bookkeeping, and FCAS, MNSP,
generic-constraint and area-balance costs have no per-device expression to join, so the gap would
only partly close.

## Consequences

- `ProductionCostExpression` holds energy offer costs only; it does not sum to the objective.
- Penalty costs are read from `replication_results`' `constraint_violations` table.
