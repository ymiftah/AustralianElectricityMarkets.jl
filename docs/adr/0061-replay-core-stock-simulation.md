# 0061. Range replay as a stock PowerSimulations `Simulation` per trading day

## Status

Accepted. Package ownership and replay entry points are superseded by
[0065](0065-replay-system-package-boundary.md). Other model and execution decisions remain in force.

## Context

`replicate_interval` built and solved a fresh `DecisionModel` per interval. Replaying a day meant
288 builds, and the build dominated the time. The replay inputs that change between intervals are
already `PSI` parameters that a simulation step updates: generic-constraint right-hand sides and
invoked masks, FCAS effective offers and band prices, loss demand coefficients, MNSP offers, ramp,
availability and initial-power series, battery ceilings and tie-break scales. A stock
`PSI.Simulation` can therefore step one built model through a range.

Some model structure is fixed at build and cannot follow a step:

- the Market Price Cap, which scales every constraint violation penalty;
- the set of modelled generic constraints;
- the tie-break pairs: which bands of which units are price-tied, read from the offer prices at
  build ([0036](0036-energy-tie-break.md)).

## Decision

- **The replay path is the only interface.** `replicate_range(db, start, stop; parts, chunk, ...)`
  builds one `PSI.Simulation` per chunk and steps it; `start == stop` replays one interval through
  the same path. `replicate_interval` (a `DecisionModel` built and solved per interval), its
  `replicate_interval(sys, db, t)` method and the single-interval `replication_system(db, t)` are
  removed, so every replay result comes from a model built once and stepped. The script
  `scripts/replicate_interval.jl` becomes `scripts/replicate_range.jl`, and
  `scripts/diagnose_infeasible.jl` builds the one-interval simulation.
- Each chunk's `PSI.Simulation` has a one-interval `DecisionModel` of `replication_template` on a
  `replication_system` over the chunk plus the two stamps after it, with `InterProblemChronology`
  and no initial conditions: every step starts from its own published `INITIALMW`.
- **Chunks break at every trading-day start (the interval ending 04:05) and at the interval ending
  00:05 on 1 July**, plus every `chunk` period when one is given. Price bands for a trading day are
  fixed at the 12:30 Day -1 gate closure and cannot change in a rebid (AEMO *Spot Market Operations
  Timetable* v1.12 §2.1, pp. 5-6; NER 3.8.5, 3.8.22): rebids change quantities only. Loss factors,
  which refer prices to the regional reference node, change only with the financial year. So the
  tie-break pairs are constant within a chunk and the Market Price Cap is single-valued. A rebuild
  per trading day is chosen over a model that re-derives its tie groups at each step, because PSI
  has no step hook for adding or removing constraints.
- `replication_system` transforms its series into one-interval forecast windows, one per stamp: a
  simulation step reads a window of exactly the model horizon, and the former two-interval windows
  of [0052](0052-one-step-replication-horizon.md) fail at the first update.
- **The pre-flight checks still run per chunk** and throw before the build: `check_tie_break_pairs`
  (with `:tie_breaks`), one Market Price Cap, `check_fcas_services` and `check_dispatch_envelope`
  over the chunk's intervals. The last replaces the build-time envelope check that a recurrent build
  cannot run, since its parameters have no values before the first step.
- A generic constraint invoked at none of a chunk's intervals is left out of that chunk and
  reported in `skipped_constraints` as `:never_invoked`. One invoked at some intervals is built, and
  its invoked mask zeroes its slack cost at the others; such a masked slack is not reported as a
  violation.
- `parts` (`REPLICATION_PARTS`) selects the modelled families, and every check follows it: the
  constraint-input records only with `:generic_constraints`, the MNSP offers only with `:losses`,
  the battery dispatch series only with `:batteries`. A generic constraint whose terms need a
  left-out family is left out and reported with its reason (`:unmodeled_fcas_service`,
  `:unmodeled_device_type`); any other unbuildable reason still throws. `:tie_breaks` without
  `:batteries` throws when a battery carries tie-break scales, since the scales of a tie group are
  relative to its widest band, which may be the battery's.
- `exclude_constraints` defaults to an empty `Dict`, and a name that is not a generic constraint of
  the system throws. Exclusions are applied before term checks and preserve their requested skip
  reason. Among remaining constraints, a failure outside the omitted families takes precedence
  over a tolerated failure, independently of term order. FCAS pre-flight checks exclude storage
  contributors only when `parts` deliberately omits batteries; standalone checks remain strict.
  A battery-only FCAS service is omitted with them, and its constraint references are diagnosed
  through the omitted contributor types rather than as a missing FCAS model.
- Model-level and service-level Market Price Cap overrides must be finite and strictly positive.
  This keeps every active violation penalty positive without changing the published cap schedule
  or the linear formulation. AEMC's *Schedule of reliability settings, 2026-27 financial year*
  (27 February 2026, p. 1) publishes positive caps of $20,300/MWh for 2025-26 and $23,200/MWh for
  2026-27. This is configuration validation, with no departure from the published cost terms.
- **No per-run parameter-storage switch.** PSI decides which parameters a simulation store keeps
  through the type-level `should_write_resulting_value`, so a per-call switch needs process-global
  state, which #196 used and review rejected. The replay keeps PSI's default (time-series
  parameters are stored). A per-simulation switch belongs in the pinned PSI fork.

## Consequences

- A chunk is built once and stepped; its results are reopened from the chunk folder, so the system
  of a solved chunk can be collected.
- A range crossing 04:05 pays one build per trading day.
- The stock-simulation tests compare each step with a standalone
  solve on toy systems whose inputs change between the two steps.
- The store keeps every replication time-series parameter, which costs memory and disk on long
  ranges until the PSI fork offers a per-simulation switch.
