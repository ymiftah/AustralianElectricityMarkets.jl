# 0103 Aggregated generic constraint containers

## Status

Accepted. Builds on [0100](0100-one-key-type-per-family-and-role.md) and the free-row invocation bounds of [0101](0101-aem-writes-aemsim-reads.md).

## What

- Every container of the generic constraints is one container per role, keyed by the `GenericConstraint` type with an empty meta, the constraint name on the first axis and the time steps on the second: `NEMConstraintRHSParameter`, `GenericConstraintInvocationParameter`, `NEMConstraintLHS`, `NEMConstraintLimit` (with its dual) and the slack containers. The slack containers hold only the constraints with that direction (`LE` or `EQ` for up, `GE` or `EQ` for down).
- A constraint that is unavailable, excluded or pruned is absent from every axis; a model with no `GenericConstraint` service model has no shared containers.
- Result keys lose the per-constraint meta (`NEMConstraintLimit__GenericConstraint__<name>` becomes `NEMConstraintLimit__GenericConstraint`); select a constraint by the `name` column.

## How

- The per-name service models stay, so PSI's expansion, the `"filter_function"` exclusion, pruning and contributing-device bookkeeping are unchanged. Per constraint, the argument stage reads its two series and creates its right-hand side parameter variables, held in build scratch (so each keeps the column position the per-constraint container gave it). The first model stage adds the shared containers over the held constraints; every model stage adds that constraint's terms, slacks, rows and objective terms into them, in PSI's service visiting order. Row, column and objective-term creation order is therefore that of the per-name build.
- PSI's service update reads one service named by the key's meta, which an empty meta cannot name. AEMSim defines `PSI.update_container_parameter_values!` for the two parameter types: it reads each constraint's series with PSI's own per-service update of the shared array, then resets the registered bound targets once for the invocation parameter.
- The private PSI calls used are listed in `psi_compat.jl`.
- `read_fcas_prices` splits the one `NEMConstraintLimit` dual frame by `name` and sums in the same constraint order. `read_constraint_violations` reads the shared slack frames and keeps the per-constraint `variable` string (`<slack key>__<name>`). The baseline `compare.jl` merges per-constraint tables of older snapshots into the shared key before comparing.

## Why

- PSI pays per container key at build, at every step (state writes, one parameter update per parameter key) and in result readers. About 1 280 constraints each had their own parameters, expression, limit and slacks, roughly 6 000 of 9 000 container keys; sharing cut the per-step parameter update about sevenfold with identical results.
- Creating the shared containers earlier than the per-name order moved columns and landed on another degenerate dual vertex, so the per-name creation order is kept.

## Market correctness

No bound, row, coefficient or cost term changed: each constraint keeps its sense and `Interval` bounds, its invocation-driven free rows (AEMO *Constraint Formulation Guidelines*: a non-invoked constraint is not in the dispatch) and its slack priced at the CVP factor times the Market Price Cap (*Schedule of Constraint Violation Penalty Factors* v8.0).
