# 0010. A Phase 2 formulation must emit a vacuous constraint where `"invoked" == 0`, not skip it

## Status

Accepted

## Context

`GenericConstraint`'s `"invoked"` series (see `add_nem_constraints!`) is `0.0` at any interval
this constraint wasn't actually enforced. A `PowerSimulations.jl` formulation consuming it will
be tempted to skip building a constraint at those `(component, t)` cells entirely, since there's
nothing to enforce.

That skip breaks dual-variable readback. PSI's `_calculate_dual_variable_value!` broadcasts over
the whole dense `(component, t)` container; a cell with no constraint object registered throws
`UndefRefError` rather than reading back a sensible dual.

## Decision

At every interval `"invoked" == 0`, a Phase 2 formulation must still emit a constraint — a
vacuous one, e.g. `0.0 <= 1.0` — rather than omit the cell. It adds nothing to the LHS and reads
back a dual of exactly `0.0`, which is also the mathematically correct answer: a constraint not
in force has no shadow price.

## Consequences

- Every `(component, t)` cell in a `GenericConstraint`-derived container stays defined for the
  full horizon, regardless of `"invoked"`.
- This is guidance for Phase 2's formulation code, not something Phase 1 enforces itself — Phase
  1 carries no PSI dependency. Recorded now so it isn't rediscovered the first time Phase 2 hits
  the same `UndefRefError`.
