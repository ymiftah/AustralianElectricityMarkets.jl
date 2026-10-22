# 0029. Diagnosis of the two infeasible validation intervals

## Status

Accepted

## Context

The June 2026 validation run failed to solve two intervals, 2026-06-13T04:15 and
2026-06-29T11:55 (MMSDM `SETTLEMENTDATE`). The pipeline only reported `RunStatus.FAILED`, so the
cause was unknown. `scripts/diagnose_infeasible.jl` now rebuilds one interval through the
pipeline, prints the JuMP termination, primal and raw statuses, and asks HiGHS for an
irreducible infeasible subsystem with `JuMP.compute_conflict!`. When HiGHS returns no conflict it
falls back to `relax_with_penalty!` and lists the constraint families that carry violation.

## Findings

Both intervals: `termination_status = INFEASIBLE`, `raw_status = kHighsModelStatusInfeasible`
(a true infeasibility, not a numerical `FAILED`). HiGHS returned a three-row conflict, all on the
first-interval `ActivePowerVariable` of the `HydroDispatch` unit `HUMENSW`:

- the variable lower bound `0`;
- the variable upper bound from the registered rating (0.70 per unit);
- the `RampConstraint` "up" row, an upper bound of `-0.00395` per unit (06-13, `INITIALMW = -0.395 MW`) and `-0.00365`
  per unit (06-29, `INITIALMW = -0.365 MW`).

`DISPATCHLOAD` for `HUMENSW` at both intervals: `INITIALMW` slightly negative (auxiliary load of
an offline unit), `AVAILABILITY = 0`, `RAMPUPRATE = 0`, `RAMPDOWNRATE = 0`, `TOTALCLEARED = 0`.
The hard ramp-up row `x <= INITIALMW + RAMPUPRATE * dt` therefore has a negative right-hand side,
which no non-negative dispatch satisfies. No generic constraint, FCAS or interconnector row is
in the conflict, so the earlier hypothesis (hard FCAS MaxAvail or BDU rows, the unmodelled
`SVML_ZERO` constraint) does not explain these two intervals.

## Decision

Record the diagnosis; the model is not changed here. NEMDE treats the unit ramp rate constraint
as elastic with `DeficitRampRate`/`SurplusRampRate` variables (AEMO, Constraint Violation Penalty
Factors v8.0, Table 1 item 3; the same document lists the Interconnector Capacity Limit, item 5, the
UIGF cap, item 12, the unit MaxAvail row, item 14, and the FCAS MaxAvail and ramping rows, items
19 to 21, as elastic). The pipeline keeps the ramp rows hard, so any unit whose `INITIALMW` lies
outside `[0, ...]` with a zero ramp rate makes the model infeasible. The follow-up is to make the
unit ramp rows elastic at the item 3 penalty, or at minimum to clamp the ramp envelope to the
variable bounds, and to re-run the two intervals.

## Consequences

- Two of ten validation failures are explained by one data corner case, not by missing
  constraints or FCAS rows.
- Every other hard row listed in the 2026-10-06 Phase 3 gap audit remains a candidate for the same kind of failure.
- The pipeline log reports the skipped generic constraints by reason, and `replicate_interval`
  returns them in `skipped_constraints`.
