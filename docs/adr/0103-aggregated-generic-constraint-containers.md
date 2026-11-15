# 0103. Aggregated generic constraint containers

## Status

Accepted. Builds on [0100](0100-one-key-type-per-family-and-role.md) and
[0101](0101-aem-writes-aemsim-reads.md) section 5.

## Context

PowerSimulations (PSI) expands the aggregated `ServiceModel(GenericConstraint, LinearFactorLimit)` into one
service model per available constraint, and the formulation built every container of a constraint with
`meta = name`. On the real trading day of 2026-06-04 that is about 1 280 constraints, each with its own
`NEMConstraintRHSParameter`, `GenericConstraintInvocationParameter`, `NEMConstraintLHS`, `NEMConstraintLimit`
(with a dual) and up to two slack containers. That is 2 560 of the 2 834 parameter keys and about 6 000 of the
model's 9 000 container keys.

PSI pays per key: at build (problem storage and store open), at every simulation step (`write_results!` and
`_update_simulation_state!` loop over every key, and the parameter update runs once per parameter key), and in
the result readers, which read the keys one by one.

## Decision

Every container of the generic constraints is one container per role, keyed by the `GenericConstraint`
type with an empty meta, with the constraint name on the first axis and the time steps on the second. The
slack containers hold only the constraints with that direction (`LE` or `EQ` for up, `GE` or `EQ` for down).

The per-name service models stay, so PSI's expansion, the template's `"filter_function"` exclusion, the pruning
of unbuildable constraints and the contributing-device bookkeeping are unchanged. Only the construction
differs:

- Argument stage, per constraint: reads the constraint's two series and creates the right-hand side parameter
  variables, but holds them in the build scratch. The variables are created here, not later, so each keeps the
  column position the per-constraint container gave it.
- First model stage: adds the shared parameter containers (filled from the held values), the expression, the
  constraint and the dual containers, and the slack containers, over the constraints the argument stage held.
- Every model stage, per constraint: adds the terms, the slacks, the rows and the objective terms of its own
  constraint into the shared containers, in the order PSI visits the service models.

Row, column and objective-term creation order is therefore the order of the per-name build, so the LP differs
from the per-name build only in the container it is stored in.

PSI's service update reads one service named by the parameter key's meta, which an empty meta cannot name.
AEMSim defines `PSI.update_container_parameter_values!` for the two generic constraint parameter types: it
reads each constraint's series in turn with PSI's own per-service update of the shared array, then, for the
invocation parameter, resets the registered bound targets once. `PSI.add_bound_target!` and the stock
`DenseAxisArray` lookups already address a multi-constraint container (the parameter array's rows are keyed by
series UUID, the multiplier's by name).

No PSI fork change is needed. The private PSI calls the shared containers make (`_get_time_series_name`,
`_to_is_interval`, `_time_series_parameter_eltype`, `_set_parameter_at!`, `_set_multiplier_at!`,
`_update_parameter_values!`, `_apply_bound_targets!`) are listed in `psi_compat.jl` with the other internals AEMSim uses.

Readers:

- `read_fcas_prices` reads the one `NEMConstraintLimit` dual frame and splits it by the `name` column, summing
  in the same constraint order as before.
- `read_constraint_violations` reads the shared slack frames, whose `name` column is the constraint. Its
  `variable` column keeps the per-constraint key string (`<slack key>__<name>`) so the table is unchanged.
- The replay baseline `compare.jl` merges the per-constraint tables of an older snapshot
  (`<kind>/<Type>__GenericConstraint__<name>`) into the shared key, filling a missing `name` column from the key,
  before comparing; the FCAS dual sums and the slack masking read the shared tables by `name`. Snapshots in
  either form compare equal for equal models.

## Consequences

- Result key names change: `NEMConstraintLimit__GenericConstraint__<name>` becomes
  `NEMConstraintLimit__GenericConstraint`, and likewise for the expression, parameters and both slacks. Code that
  selected a constraint's key by its meta selects the rows of the one frame by `name`.
- A `GenericConstraint` that is unavailable, excluded or pruned is absent from every axis, as it had no
  containers before. A model with no `GenericConstraint` service model has no shared containers.
- Replay results are equal up to the solver's choice among degenerate dual vertices (below).

## Measurements

Real replay of 2026-06-04, `scripts/replay_batch.jl --start 2026-06-04T04:05:00 --intervals 12`, one process
each, before and after.

| Measure | Before | After |
| --- | --- | --- |
| Realized tables (variable, dual, parameter, expression) | 5 952 | 837 |
| Dual tables | 1 413 | 134 |
| Parameter tables | 2 844 | 286 |
| Variable tables | 1 694 | 416 |
| Model build (`days.csv`) | 11.5 s | 9.7 s |
| Execute, 12 steps | 92.6 s | 31.0 s |
| Parameter update, per step | 5.9 s | 0.82 s |
| Update state, 12 steps | 2.53 s | 0.83 s |
| Comparison (`compare_s`) | 10.5 s | 6.5 s |

The parameter update dominated the non-solve time: it ran the PSI update path once per generic constraint
parameter key. The batch outputs `comparison_prices.csv`, `comparison_fcas_prices.csv`,
`comparison_interconnectors.csv`, `constraint_violations.csv`, `ramp_violations.csv` and
`skipped_constraints.csv` are byte-identical; `comparison_dispatch.csv` differs in one cell by `3e-14` MW.

## Equivalence

The replay gate against the reference capture (`capture.jl` then `compare.jl --invariants --mask-gc-slacks
--report-only 'FCASCapacityVariable|FCASOfferBandVariable|FCASSideCapacityVariable|MNSPLinkBandVariable'`)
passes on the mock replay (3 intervals, max gap 0) and on the 12 real intervals (max gap below `1e-12` in three
fresh processes), with every generic constraint slack equal per constraint and interval.

The reference itself is not bit-stable across processes. The pre-change code, run four times, produced the
same gating values every time but the non-gating duals of 15 keys (a `NEMConstraintLimit` of twin islanded
constraints and the `FCASJointCapacityConstraint` rows) in two of the four runs. Two dumps of the pre-change
LP's rows, from two processes, differ from each other from row 532 on, so the construction order of some PSI
containers is not deterministic across processes. An intermediate form of this change that created the shared containers
earlier (so the generic constraint columns moved relative to the FCAS columns) landed on another degenerate
dual vertex twice, once enough to move the `derived/fcas_sum__RAISE` gate by 8.33 per unit (one dollar per MWh); the final form keeps
the per-name creation order and passed three of three.

## Market correctness

No bound, row, coefficient or cost term changed. Each constraint keeps its stored sense and `Interval` bounds,
its invocation-driven free rows (AEMO *Constraint Formulation Guidelines*: a constraint not invoked in the
interval is not in the dispatch), and its slack priced at the constraint violation penalty factor times the
Market Price Cap (AEMO *Schedule of Constraint Violation Penalty factors* v8.0).
