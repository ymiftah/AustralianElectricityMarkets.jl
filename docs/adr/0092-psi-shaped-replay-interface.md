# 0092. The replay interface is PowerSimulations-shaped

## Status

Accepted. Removes the replay orchestration in `scripts/` (`ReplaySimulation`, `ReplayResults`,
`ReplayWorkflow`) that 0088 and 0090 still referred to. The template decisions of 0088 and 0090
remain in force.

## Context

An API-fit review of the replay against the PowerSimulations (PSI) workflow found the building blocks
PSI-idiomatic (`template_nemde`, the formulations, a stock `Simulation`, standard result readers), but
the orchestration lived in repository scripts:

- `replication_decision_model(template, sys, initial_time; ...)` wrapped `DecisionModel`, fixed the
  horizon, resolution and interval and dropped every other PSI keyword (for example
  `calculate_conflict`).
- The pre-flight was a hand-ordered sequence inside `scripts/replay_simulation.jl`: step and
  financial-year checks, tie-break pairs, never-invoked constraints, `exclude_unmodeled_services!`,
  the template, FCAS and envelope checks, then the Market Price Cap (MPC). A user without the script
  had to copy it.
- The MPC reached a model by two routes: the settings `ext` and a `"market_price_cap"` service-model
  attribute.
- Results post-processing (`replication_results`, `compute_fcas_prices`) and the loss-gap check were
  modules that tests and the tutorial loaded with `include("../../scripts/...")`.
- `prepare_replay_forecasts!` duplicated the transform PSI applies itself.

## Decision

- **A PSI decision problem.** `NEMDispatchProblem <: PSI.DefaultDecisionProblem`, built with
  `DecisionModel(NEMDispatchProblem, template, sys; kwargs...)`. Horizon, resolution and interval
  default to one dispatch interval; every other keyword goes to `PSI.Settings`.
- **Build-time checks in `PSI.validate_template`.** It dates the MPC from the model's initial time at
  every build (unless `market_price_cap` is passed), prices the area-balance slacks through the
  network model's `slack_cost`, and runs `check_template_against_sys` and `check_fcas_services` before
  PSI prunes device models without available devices. `Simulation` sets each model's initial time
  before this hook runs.
- **Range checks in `prepare_replay!(sys, template, steps)`.** PSI gives a model one execution per
  simulation step, so the step count is not visible in `validate_template`; the checks that need the
  range (steps, financial year, tie-break pairs, never-invoked constraints, exclusions, dispatch
  envelope) run here. It also attaches the five-minute forecasts, idempotently.
- **One MPC route:** the settings `ext`.
- **Results as reader methods.** `read_prices` and `read_fcas_prices` gain methods for PSI results
  with the published columns; `read_solved_interval` mirrors `read_published_interval`, so
  `compare_intervals` is a join. `read_constraint_violations` returns a fixed row order.
- **Data and range helpers in the package:** `check_replay_inputs`, `trading_day_steps`,
  `replay_chunks`, `nemde_optimizer`. Superseded: `check_replay_inputs` was removed, and
  `nem_system` now validates these inputs at the end of the build.
- **No `replicate_range` function.** The documented interface is the PSI code itself: `nem_system`,
  `prepare_replay!`, `DecisionModel`, `SimulationModels`, `SimulationSequence`, `Simulation`,
  `build!`, `execute!`, then the readers. `scripts/` keeps only the overnight batch runner, built on
  these functions.

## Consequences

- A replay written by a PSI user reads like any PSI simulation; `calculate_conflict` and other PSI
  settings are reachable, which replaces `scripts/diagnose_infeasible.jl`.
- A failed check inside `validate_template` surfaces as a failed build (PSI catches build errors),
  not as an exception from the constructor.
- `read_interconnector_loss_gaps` reports `weighted_loss_price` in `$/MWh`; the script reported the
  raw balance dual under that name.
- Each step was checked against a baseline replay of 2026-01-01 04:05 to 04:30: prices, dispatch,
  flows, FCAS prices, violations, skipped constraints and objectives are unchanged.
