# 0008. A constraint's time-series grid comes from `date_range`, minus its last point

## Status

Accepted

## Context

`add_nem_constraints!` attaches `"rhs"` and `"invoked"` `Deterministic` series to every
`GenericConstraint`. The grid those series are indexed on was originally derived from
`unique(invoked.SETTLEMENTDATE)` — whichever intervals any constraint happened to be invoked at.

Two failure modes were found empirically against real cached data, not reasoned about:

- **Deriving the grid from invocations makes it too short.** A `GENCONID`'s rows only cover the
  intervals it was actually invoked at, and real data contains intervals NEMDE dispatched through
  with nothing bound at all. The resulting series was shorter than every other series on the same
  `System` (`set_demand!`'s, say), and `transform_single_time_series!` raised
  `ConflictingInputsError` on PowerSystems' cross-component horizon check.
- **Keeping all of `date_range` makes it one row too long.** `date_range`'s N+1 timestamps label
  N interval *starts*. `read_fcas_bids` and `set_demand!` already follow a half-open
  (`start <= x < stop`) convention, so retaining the final point produces a series one row longer
  than theirs and the same horizon error from the opposite direction.

## Decision

The grid is `collect(date_range)[1:(end - 1)]` — the caller's requested range, dropping its last
point.

Values are carried forward across intervals a constraint was not invoked at, and the companion
`"invoked"` mask (`1.0`/`0.0`) is the authoritative record of which intervals were real. A
carried-forward `"rhs"` value must not be treated as enforced without consulting `"invoked"`.

## Consequences

- Every `GenericConstraint`'s series spans exactly what the caller asked for, so it composes with
  any other series attached to the same `System`.
- Both regressions are reproducible: reverting to `unique(invoked.SETTLEMENTDATE)`, or keeping
  the N+1 point, each reproduces `ConflictingInputsError`. The test suite pins the length against
  both.
- A caller wanting a different convention must change `date_range`, not the grid derivation.
