# 0101 AEM writes every NEMDE input; AEMSim only reads the System

## Status

Accepted. Typed-system rules are in [0095](0095-typed-nem-system.md), the run interface in [0092](0092-psi-shaped-problem-interface.md), key types in [0100](0100-one-key-type-per-family-and-role.md).

## What

- AEM writes every input the model reads, once, in `_set_nemde_inputs!(sys)`, which `nem_system(db, NEMDEConfiguration(); date_range)` runs last. AEMSim never writes to the System (no PSY or IS mutator, `add_time_series!`, `set_available!` or `ext` write).
- One writer per series name; the forecast transform into five-minute windows is last and nothing is added after it. `validate_template` refuses a System whose device or service availability changed after the stage.
- Dispatch range: `date_range = first(steps):5min:(last(steps) + 10min)`. `dispatch_intervals(sys)` is all stamps but the last two; the dispatch intervals (at least one) must lie in one trading day (04:00) and one financial year (1 July), where the Market Price Cap, penalties and loss factors change.
- Band prices are typed day-constants `band_prices::NTuple{10, Float64}` on the energy, FCAS and MNSP bids (energy referred by the loss factor and rounded, padded with `0.0`); `nem_system` throws if they vary within the range. AEMSim adds band costs once as invariant objective terms.
- The problem type selects the mode: `NEMDispatchProblem` (observed state) or `NEMClosedLoopDispatchProblem` ([0102](0102-closed-loop-problem.md)).

## How

- Writer order is in the `_set_nemde_inputs!` docstring; kernels (`src/derivations/`) are scalar functions of an `NEMUnitState`, looped over the range by writers (`src/system/nemde_inputs/`); AEMSim imports them.
- Exclusions: a constraint never invoked or with no available device is built `available = false` and recorded in `unavailable_constraints`; `template_nemde(; exclude_constraints)` filters the aggregated `GenericConstraint` service model; `validate_template` deletes the per-name model of a constraint using something the template does not model (blocked ones throw), via `template_skipped_constraints(sys, template)`.
- Every generic constraint row is an `Interval` row whose bounds follow `GenericConstraintInvocationParameter` (a fork `ConstraintBoundParameter` read from the `invoked` series), so a non-invoked row is free. Slacks cost CVP factor x Market Price Cap.
- Per-step updates use fork parameters (`ConstraintCoefficientParameter`: loss demand, FCAS slopes, tie-break scales; `ConstraintBoundParameter`: invocation) under PSI's stock update. AEMSim overrides the update only for the shared generic constraint containers ([0103](0103-aggregated-generic-constraint-containers.md)), the closed loop and the fast-start runs ([0106](0106-fast-start-two-run-dispatch.md)).
- Initial MW and MNSP flow are read through `_initial_mw_accessor` and `_mnsp_initial_flow_accessor`. FCAS kernels are unit-agnostic (the writer divides by the base);
- FCAS prices are not unique at degenerate duals (twin R6 and R60 rows), so the comparison gate (`compare.jl --invariants`) gates variables, the objective, energy price duals and summed FCAS requirement duals, and reports the rest.

## Why

- PSI expects the System prepared by its builder, the model only reading it, and per-step updates being PSI's own. A free row needs no extra column, unlike an unpriced invocation-mask relaxation, which moved degenerate duals.

## Market correctness

- Band prices fixed per trading day: AEMO *Spot Market Operations Timetable* v1.12 s2.1 (NER 3.8.5 to 3.8.7B, rebids 3.8.22); *FCAS Model in NEMDE* s2.
- A non-invoked constraint is absent from dispatch: *Constraint Formulation Guidelines* s8.1.
- Penalty is CVP factor x Market Price Cap: *Schedule of Constraint Violation Penalty Factors* v8.0. FCAS price ties follow the solver path (item 53; *Constraint FAQ* Q3.19).

## Known limits

- A `Simulation` can step one window past `dispatch_intervals(sys)` without the range rule checking it; no caller does.
