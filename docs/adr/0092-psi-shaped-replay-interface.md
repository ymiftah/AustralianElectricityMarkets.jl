# 0092 The replay interface is PowerSimulations-shaped

## Status

Accepted. Input ownership and the problem-type switch are in [0101](0101-aem-writes-aemsim-reads.md); the template scope is in [0090](0090-template-is-the-replay-scope.md).

## What

- The replay is plain PowerSimulations (PSI) code: `nem_system`, `DecisionModel(NEMDispatchProblem, template, sys; kwargs...)`, `SimulationModels`, `SimulationSequence`, `Simulation`, `build!`, `execute!`, then the readers. There is no `replicate_range` function.
- `scripts/` keeps only the overnight batch runner, built on these calls.

## How

- `NEMDispatchProblem <: AbstractNEMDispatchProblem <: PSI.DefaultDecisionProblem`. The constructor fixes horizon, resolution and interval at one dispatch interval and rejects them and `ext`; every other keyword goes to `PSI.Settings`, so `calculate_conflict` and similar are reachable.
- Pre-flight runs in `PSI.validate_template`, before PSI prunes device models without devices. It dates the Market Price Cap (MPC) from the model's initial time on every build (the `market_price_cap` keyword overrides), prices the area-balance slacks through the network model's `slack_cost`, and runs `check_template_against_sys`, `check_fcas_services` and `check_dispatch_envelope`. A failed check surfaces as a failed build, since PSI catches build errors.
- The MPC has one route, the settings `ext`.
- Results are reader methods: `read_prices` and `read_fcas_prices` accept PSI results with the published columns, `read_solved_interval` mirrors `read_published_interval` so `compare_intervals` is a join, and `read_constraint_violations` has a fixed row order.
- Package helpers: `trading_day_steps`, `replay_chunks`, `nemde_optimizer`.

## Why

- A replay written by a PSI user reads like any PSI simulation, with no script to copy.
- Replay-range checks are not in `validate_template`, which cannot see the step count; `nem_system` enforces them when it builds the range ([0101](0101-aem-writes-aemsim-reads.md)).
- `read_interconnector_loss_gaps` reports `weighted_loss_price` in `$/MWh`.
