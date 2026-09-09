# 0010. Filling an uninvoked `(component, t)` cell: vacuous constraint vs. a custom dual-reader

## Status

Proposed — a trade-off for Phase 2 to weigh with real formulation code, not a closed decision.
This finding is inherited from prior branch experimentation building the PSI service
formulation, not verified independently in this phase.

## Context

`GenericConstraint`'s `"invoked"` series (see `add_nem_constraints!`) is `0.0` at any interval
this constraint wasn't actually enforced. A `PowerSimulations.jl` formulation consuming it will
be tempted to skip building a constraint at those `(component, t)` cells entirely, since there's
nothing to enforce.

PSI's `ServiceModel` constraint containers are typically dense arrays pre-allocated over the
full `(component, timestep)` grid — not something a formulation author controls — and
`_calculate_dual_variable_value!` broadcasts over that whole container to extract duals. A cell
with no `ConstraintRef` assigned throws `UndefRefError` rather than reading back a dual.

## Decision

Two ways to keep every cell readable, neither implemented or benchmarked yet:

- **Vacuous constraint**: emit `0.0 <= 1.0` at every uninvoked cell instead of omitting it. It
  has no decision-variable coefficients, adds nothing to the LHS, and reads back a dual of
  exactly `0.0` — the mathematically correct answer, since a constraint not in force has no
  shadow price. Cheap to write and stays inside PSI's generic dual-reading machinery, but adds
  one live `ConstraintRef`/MOI object per uninvoked cell — real per-constraint bookkeeping
  overhead in JuMP's model-build and memory footprint that scales with
  `(constrained devices × horizon length)`, even though an empty row typically presolves away
  before the solve itself.
- **Custom sparse dual-reader**: use a sparse/`Dict`-keyed container instead of PSI's dense
  array for this constraint type, and write a dual-reader that only touches cells that actually
  exist. Avoids the row bloat entirely, at the cost of bypassing PSI's generic dual-computation
  path — more custom code to write and keep in sync with PSI's own container conventions across
  version upgrades.

## Consequences

- This is guidance for Phase 2's formulation code, not something Phase 1 enforces — Phase 1
  carries no PSI dependency and builds nothing that exercises either path.
- Phase 2 should profile both options against real formulation code before picking one, rather
  than defaulting to the vacuous constraint on the strength of this ADR alone — there is no
  formulation code yet to measure against, and the row-count-vs-custom-code trade-off may look
  different once one exists.
