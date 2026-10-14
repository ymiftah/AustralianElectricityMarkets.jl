# 0052: The replication model solves one dispatch interval

## Status

Accepted. Supersedes the two-interval window in [0025](0025-replication-pipeline.md).

## Context

`replication_system` builds the interval and the one after it, because PSY rejects a
single-point `Deterministic` forecast. The `DecisionModel` then solved both steps, and only the
first was reported. In replay, the second step does not feed the first: ramp limits measure
against the `initial_mw` series of each step, and the formulation has no state carried between
steps. The two-step model therefore also paid for a second interval of binaries (1,428 instead of
714) and about 2x the variables, which dominated the solve time on hard intervals.

NEMDE solves one interval at a time, so a one-step model is the closer comparison.

## Decision

- The `DecisionModel` horizon is one dispatch interval. The model starts from the interval's
  published `initial_mw` (`INITIALMW`) as each unit's ramp base, as before.
- `replication_system` still builds two points of forecast data, because PSY needs at least two.
  Only the first is solved.

## Consequences

- Regional prices match the two-step model at all 42 test intervals (2026-01-01, 04:05 to 07:30). Dispatch, flows and losses match at 38 of 42 intervals. The four that differ are
  06:00, 06:30, 07:20 and 07:25; 06:00 and 07:25 differ materially, 06:30 and 07:20 only in unit
  dispatch. One FCAS price (07:30) differs by $1/MWh.
- Whether these differences are alternative optima or a real dependence on the second step was
  not established: the two-step objective includes the second interval, so it cannot be compared
  with the one-step objective directly.
- Mean error against NEMDE is unchanged by the horizon (regional price 7.25 $/MWh, dispatch 0.73 MW
  in both), so this change does not improve the match to NEMDE by itself.
- Mean solve time over the 42 test intervals fell from 37.4 s to 24.0 s (both means include the
  cold first interval, about 180 s).
