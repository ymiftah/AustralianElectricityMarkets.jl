# 0037. Elastic rows for the remaining hard families

## Status

Accepted

## Context

ADR 0030 made the unit ramp rows elastic and left the storage ramp rows, the FCAS MaxAvail and
BDU SCADA rows, availability and UIGF, and the interconnector flow limits hard (gap G10). A hard
row turns any conflicting input into an infeasible interval, where NEMDE relaxes the row at its
Constraint Violation Penalty (CVP) factor.

Source: AEMO *Schedule of Constraint Violation Penalty Factors* v8.0, Table 1 (nem-expert
`constraint-violation-penalty-factors/`). Factors verified against the reference files:

| Item | Constraint | Factor | File |
| --- | --- | --- | --- |
| 3 | Unit Ramp Rate | 1155 | `03-items-01-11.md` |
| 5 | Interconnector Capacity Limit (FlowDeficit/FlowSurplus) | 1150 | `03-items-01-11.md` |
| 12 | UIGF (UIGFSurplus) | 385 | `04-items-12-21.md` |
| 14 | Unit MaxAvail | 370 | `04-items-12-21.md` |
| 19 | FCAS MaxAvail | 155 | `04-items-12-21.md` |
| 20 | FCAS Joint Ramping | 155 | `04-items-12-21.md` |
| 21 | BDU Regulation FCAS SCADA Ramping | 155 | `04-items-12-21.md` |
| 22/23 | Regional demand-supply balance | 150 | `05-items-22-35.md` |
| 24 | FCAS EnablementMin/Max | 70 | `05-items-22-35.md` |

A lower factor row must break before a higher factor row: balance (150) before FCAS MaxAvail and
ramping (155) before interconnector flow (1150) before unit ramp (1155).

## Decision

- Storage ramp rows carry `UnitRampUpSlack`/`UnitRampDownSlack` at 1155 x MPC, built by the same
  helper as the generator rows. The build-time storage envelope check is removed. Under
  `NEMReplayDispatch` the per-direction availability ceilings are raised to the ramp envelope
  (ADR 0016) and, new here, so are the output and input variables' upper bounds (the device
  rating): NEMDE breaks MaxAvail (370) and the rating before the ramp row (1155), so a battery
  whose `INITIALMW` and ramp rate put the floor above its registered output is dispatched at the
  floor with zero ramp slack. The storage ramp slack therefore stays zero under replay and only
  acts in `NEMLookaheadDispatch`, where the envelope is a variable and cannot be pre-raised.
- FCAS MaxAvail (item 19) becomes a row `capacity - slack <= MaxAvail` with `FCASMaxAvailSlack`
  at `FCAS_MAXAVAIL_CVP_FACTOR` (155), for single-sided and both-side (BDU) capacity variables.
  The BDU SCADA row (item 21) carries `FCASBDURampingSlack` at `FCAS_BDU_RAMPING_CVP_FACTOR`
  (155). Both are built only when the service model has `use_slacks = true`, like the other FCAS
  slacks; without slacks MaxAvail stays the variable's upper bound. A device disabled by the
  enablement pre-conditions is still pinned to zero, since that is a precondition and not a row.
- A battery's static rating is thus soft in the same sense as a generator's `AVAILABILITY`; the
  rating is raised at build, not relaxed by a priced slack.
- Interconnector flow limits (item 5) carry `InterconnectorFlowSurplusSlack` (upper) and
  `InterconnectorFlowDeficitSlack` (lower) at `INTERCONNECTOR_FLOW_CVP_FACTOR` (1150), always
  elastic like the ramp rows. The loss breakpoint range stays a hard bound: the Schedule has no
  penalty item for it (items 16 and 17 concern MNSP availability and losses, which belong to the
  MNSP work, G9), so it is a modelling range, not a NEMDE constraint.
- `replicate_interval` returns `constraint_violations`, one row per non-zero slack of every
  elastic family (`family`, `name`, `DateTime`, `MW`, `direction`, `variable`), so no relaxation
  is silent. `direction` is `up` for a slack relaxing a `<=` row and `down` for one relaxing a
  `>=` row, refined for the FCAS enablement slacks (`_lower` keys) and for joint ramping slacks, whose
  sense depends on the device (a load's `LOWERREG` row is the `<=` form). Area balance rows are
  equalities: `up` is a deficit (demand unserved) and `down` a surplus. The table covers the
  PowerSimulations slack containers of these families only; slacks built as bare JuMP variables
  (the tie-break terms) are not listed.
  Interconnector slacks are built whatever the device model's `use_slacks`, as NEMDE's limit is
  always soft; the FCAS slacks follow the service model's `use_slacks`. A `FCASMaxAvailSlack`
  is created for disabled `(device, t)` as well, with a vacuous row; it is never active. `ramp_violations` is kept as the unit-ramp view of the same table.
- A toy test fixes the ordering for the pair area balance (150) against unit ramp (1155): a
  shortfall is left unserved rather than bought with a ramp violation.

## Not done: unit MaxAvail (item 14) and UIGF (item 12) as soft rows

NEMDE breaks MaxAvail (370) and UIGF (385) before the unit ramp row (1155). That order is already
realised in the data: `set_nem_dispatch_limits!` raises the upper dispatch limit to the ramp-down
floor, and the storage ceilings are raised the same way, so a ramp-down floor above availability
is resolved by letting the unit sit at its floor, which is MaxAvail broken before ramp. A soft
availability row would have a slack that is zero in every case the data does not already resolve
(`0 <= power <= availability` is never infeasible once the ramp row is elastic), so it would add
a variable per unit and interval without changing a solution. Making it soft would only matter
if the raise were removed from the setter, which would change `max_active_power` for every
consumer and ADRs 0013 and 0016; that is a data-model change, not a G10 row. `_check_dispatch_envelope`
is kept for the same reason as in ADR 0030: it only fires on data that bypassed the setter.

## Consequences

- The model is feasible whenever the variable bounds are, for storage ramps, flow limits and,
  with slacks, FCAS MaxAvail and SCADA rows. Slacks are zero in ordinary solves (tested).
- Hard rows that remain: availability and UIGF bounds (above), the loss breakpoint range, and the FCAS and generic-constraint rows when the owning service
  model has `use_slacks = false`.
- The flow-limit and storage ramp slacks are built whatever `use_slacks` is, so a build needs a
  Market Price Cap for every interval: builds dated before 2024-07-01 throw unless the model's
  `"market_price_cap"` setting supplies one.
- Objective scaling: the largest implemented slack factor is 1155. At the 2026-27 Market Price
  Cap of $23,200/MWh and a system base of 100 MW, a unit ramp slack coefficient is about
  2.2e8 per per-unit, against offer coefficients of about 0.08 to 8 per per-unit, a spread of 1e9
  to 1e10. HiGHS solved the toy and mock problems, but `replicate_interval` sets
  `mip_abs_gap = 1e-10`, which is below double-precision resolution of an objective of that
  magnitude whenever any slack is active, so a MILP can stall on the gap test rather than finish.
  No real-data solve was run for this change. If one does, the first hints to try are
  `user_objective_scale` and `user_bound_scale`, then a relative gap in place of the absolute one,
  before lowering any factor.
- After the MNSP work (`gate-g9-mnsp`), MNSP link flows are hard-bounded by `MAXAVAIL` (item 16,
  365) while the flow limit (item 5, 1150) is elastic, so a flow-limit lower bound above the
  available link capacity spends the 1150 slack where NEMDE would break 365 first. This is
  deferred with the MNSP availability and losses rows (items 16 and 17) and belongs on ADR 0035's
  follow-up list.
- Tests cover the penalty ordering for area balance (150) against unit ramp (1155) and against
  a flow limit (1150), and assert the factors are strictly increasing for the pairs not built
  together (FCAS 155, flow 1150, unit ramp 1155); there is no mock system holding both a
  ramp-limited unit and an interconnector under the NEM dispatch formulations, so 1150 against
  1155 is not exercised behaviourally.
- Items 14 and 12 and the loss range are the remaining part of G10.
