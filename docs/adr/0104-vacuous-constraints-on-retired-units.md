# 0104. Vacuous generic constraints on retired units are skipped, violated ones still fail

## Status

Accepted.

## Context

From mid-2024 AEMO re-registered batteries as single bidirectional units (BDU) under the Integrating
Energy Storage Systems (IESS) rule change, one battery at a time through 2024 and 2025. Once a battery
moved, its former generator and load DUIDs (for example `VBBG1`, `BULBESG1`) are no longer registered
and are absent from a replay `System`. Until it moved they were registered and dispatched; see
[0105](0105-split-battery-units-and-unregistered-terms.md) for how those are built. Some
GENCONDATA versions, still invoked in late 2024, keep naming them (for example
`#BBATTERY_E@2023-09-14#1`, `F_V_BULBESG1_LREG@2024-03-25#1`, `V_VBBG1_ZERO@2024-03-25#1`), and every
term of such a constraint is a unit term on one of those DUIDs.

A unit term whose DUID is absent from the `System` is already dropped and recorded. A constraint left
with no term was skipped as `:unknown_duid`, and the strict invoked-coverage check of `nem_system`
turned any skipped invoked version into an error, so replays of these days could not be built.

## Decision

A constraint whose every term is a dropped unit term has a left-hand side of exactly zero. At every
invoked interval `0 sense RHS` is then decidable:

- If it holds at every invoked interval (`<=`: RHS >= 0; `>=`: RHS <= 0; `=`: |RHS| <= 1e-6 MW) the
  constraint can never bind. It is not built and is recorded as skipped with reason
  `:vacuous_unknown_duid`, with its dropped terms kept in the build report. The invoked-coverage check
  accepts this reason and ignores the dropped terms of these constraints.
- Otherwise it keeps the `:unknown_duid` skip and the strict error naming the constraint.

Constraints that mix known and unknown unit terms are unchanged: built with the unknown terms dropped,
and still reported by the dropped-terms check.

## nempy comparison

nempy keeps every constraint and drops the unit terms of units without bid variables.
`SpotMarket.set_generic_constraints` (`markets.py`) adds a row with type and RHS for every constraint
set, made elastic when a `violation_cost` is given (its benchmark passes one). The unit terms are then
joined to the unit bid variables with an inner `pd.merge` in `create_unit_level_generic_constraint_lhs`
(`spot_market_backend/solver_interface.py`), so a term with no variable disappears without error. A
constraint that loses all its terms stays as a row with an empty left-hand side, and its `0 sense RHS`
is fed to the LP like any other row. A satisfiable empty row is
inactive and has no effect on dispatch or prices; a violated one is resolved by its constraint
violation variable. This decision reproduces the first case by omission and refuses the second.

## Why omitting satisfiable ones is safe

A row `0 <= RHS` with RHS >= 0 is satisfied at zero violation for every dispatch, so its violation
slack is zero at the optimum, it has no dual and contributes nothing to the objective. A violated row
would be resolved by NEMDE through the generic constraint violation penalty (AEMO, *Schedule of
Constraint Violation Penalties*, and the CVP factors in *Constraint Violation Penalty Factors*;
generic constraint penalty is `CVP factor x MPC x constraint weight`), shifting the objective by a
constant and altering the reported violation. Silently omitting it would hide that, so it stays an error
until the replay models an empty-left-hand-side violation explicitly. There is no departure from AEMO
for the omitted case.
