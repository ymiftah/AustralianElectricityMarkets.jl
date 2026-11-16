# 0104 Vacuous generic constraints on retired units are skipped, violated ones still fail

## Status

Accepted. Refined by [0105](0105-split-battery-units-and-unregistered-terms.md).

## What

- A constraint whose every term is a dropped unit term has a left-hand side of exactly zero. If `0 sense RHS` holds at every invoked interval (`<=`: RHS >= 0; `>=`: RHS <= 0; `=`: |RHS| <= 1e-6 MW) it cannot bind. It is not built and is recorded as skipped with reason `:vacuous_unknown_duid`, its dropped terms kept in the build report.
- If it is violated at some invoked interval, it keeps the `:unknown_duid` skip and the strict invoked-coverage error naming the constraint.
- Constraints mixing known and unknown unit terms are built with the unknown terms dropped.
- The vacuous skip never excuses a dropped term of a unit registered over the range: `nem_system` and `check_template_against_sys` still fail on it. Only dropped terms of unregistered units are ignored.

## How

- Constraint building (`src/system/constraints.jl`, `_is_vacuous`) decides vacuity from the invoked RHS; a missing RHS never qualifies. The invoked-coverage checks of `nem_system` and `check_template_against_sys` accept `:vacuous_unknown_duid`.
- nempy keeps every constraint and inner-joins unit terms to bid variables, so a constraint losing all terms stays as an empty-left-hand-side row (`create_unit_level_generic_constraint_lhs`). This decision reproduces nempy's satisfiable case by omission and refuses its violated case.

## Why

- Batteries re-registered as bidirectional units (IESS, 2024 to 2025) leave former generator and load DUIDs absent from the `System`, while some GENCONDATA versions still invoked in late 2024 name only them; such replays otherwise could not be built.
- A satisfiable row `0 <= RHS` has zero violation at the optimum, no dual and no objective contribution, so omitting it changes nothing. A violated row would be priced by NEMDE at CVP factor x Market Price Cap x constraint weight (AEMO *Schedule of Constraint Violation Penalty Factors* v8.0), shifting the objective by a constant and altering the reported violation. Omitting it silently would hide that, so it stays an error. There is no departure from AEMO for the omitted case.
