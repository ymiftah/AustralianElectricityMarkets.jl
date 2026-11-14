# AEM / AEMSim split along PowerSimulations' design

## Intent

AEM builds a PowerSystems `System` from NEMWEB data, and AEMSim builds and steps a
PowerSimulations (PSI) model of NEMDE from it. Today the split is blurred:

- AEMSim finishes preparing the System before the build. `prepare_replay!` writes derived series,
  replaces and removes series, removes and re-adds a service component, switches availability, and
  records exclusions in `ext`.
- The per-step path carries 10 `update_container_parameter_values!` overrides that production never
  runs: they hand back to PSI's stock update under `ObservedState`.
- AEMSim relies on fork-only per-step price updates, which force a full objective re-set every
  interval.
- The badly typed code (an `Any`-typed step cache, closures, runtime `Val`, per-step
  `get_component`) exists only to serve a simulated-state path that throws.

The user traces this to planning that never mapped how PSI is meant to be used. That map now
exists:

- `docs/psi-anatomy.md` (branch `docs/psi-anatomy`), cited against upstream PSI `cfcb71b`;
- an explainer at <https://claude.ai/artifact/1piTjmZ7DmTvm8hJpenNr6>.

This redesign realigns AEM and AEMSim with PSI's design (anatomy §A13, best practices):

- the System is fully prepared by its builder before the model is constructed;
- AEMSim only reads it;
- per-step updates are PSI's own;
- a later closed-loop replay drops in through PSI's initial conditions.

## Milestones

1. **Observed-state replay** (this design's delivery). Each dispatch interval is solved from AEMO's
   observed initial state, as NEMDE does. Exit gate: [Acceptance](#acceptance-milestone-1).
2. **Closed-loop replay** (designed for here, built later). Interval *t+1* starts from our own solve
   of interval *t*. It starts only after milestone 1's gate has passed. Full NEMDE parity is gated
   separately on modelling fast-start units, which is not in scope.

## Goals

- **G1. AEMSim never mutates the System.**
  - No `PSY.set_*!`, `add_*!`, `remove_*!`, `add_time_series!`, `replace_*`, `transform_*`,
    `set_available!` or `ext` write anywhere in `AustralianElectricityMarketsSimulations/src/`.
  - No `with_units_base` toggles, because PSI forces `SYSTEM_BASE` itself.
- **G2. AEM writes everything the model reads**, once, during `nem_system`:
  - every derived input series;
  - the tie-break service;
  - the forecast transform.

  This is the user's standing rule: AEM processes and writes all data, and AEMSim only reads the
  System.
- **G3. The interface is PSI's:**

  ```julia
  template = template_nemde()
  model = DecisionModel(NEMDispatchProblem, template, sys; optimizer, initial_time, name)
  # closed loop (milestone 2): DecisionModel(NEMClosedLoopDispatchProblem, template, sys; ...)
  sim = Simulation(...)
  build!(sim)
  execute!(sim)
  ```

  - No AEMSim entry point sits between `nem_system` and `DecisionModel`, so `prepare_replay!` is
    removed.
  - Pre-flight checks run inside PSI's `validate_template` (ADR 0092 already puts the build-time
    checks there).
  - `scripts/replay_batch.jl` is the litmus test.
- **G4. In observed mode, per-step updates are PSI's stock time-series updates.** AEMSim defines no
  `update_container_parameter_values!`, `update_parameter_values!` or `_update_parameter_values!`
  methods for that mode.
- **G5. The problem type selects the mode** (user decision, 2026-11-13).
  - `NEMDispatchProblem` is observed state and `NEMClosedLoopDispatchProblem` is closed loop, both
    `<: AbstractNEMDispatchProblem <: PSI.DefaultDecisionProblem`.
  - The template is the same for both and carries no mode.
  - Milestone 1 defines both types. Until milestone 2, a `validate_template` method on the
    closed-loop type fails with "closed-loop replay is not implemented".
- **G6. Prices are build-time constants.**
  - These enter the objective once, at build: energy, MNSP and FCAS band prices, loss-factor-referred
    offers, and the constant CVP × market price cap on constraint slacks.
  - AEM writes band prices as typed per-day data, not as series (D6).
  - The objective has no variant terms, so PSI never re-sets it between steps.
- **G7. The only per-step coefficient updates are** the interconnector loss equation's demand term,
  the FCAS trapezium slopes, the tie-break scales, and the generic-constraint invocation mask (R1).
  Tie-break scales are band-width ratios, so they change with rebids. All four use the fork's
  `ConstraintCoefficientParameter`, refreshed by PSI's stock time-series update.

## Non-goals

- Closed-loop replay itself (milestone 2). Only its seams are designed here.
- Modelling fast-start units, storage state of charge, or new NEM features.
- Improving NEMDE parity beyond the `perf/key-types` baseline.
- Reducing first-use compile time. A lower key-type count as a side effect is welcome, but it is not
  a target.
- Upstreaming fork changes. The coefficient parameter is the candidate, but this design does not
  depend on it.
- Removing `RegionalNetworkConfiguration`, which stays for high-level studies.

## Anti-goals

Any of these makes the redesign a failure, even with green tests:

- AEMSim writes to the System through a new route, including an AEM helper that AEMSim calls on an
  existing System.
- A second implementation of a state-to-input rule. Observed and closed-loop modes must call the
  same functions.
- The per-step path reads series one element at a time, looks components up by name, or holds
  `Any`-typed caches.
- The replay interface differs from PSI's: a `replicate_range`, a `prepare_*!` step, or a
  single-interval variant. The memory rule is "replay path only".
- Silent fallbacks for missing cache columns or tables. The fix for those is to repopulate with
  `force_new`.
- A series written by one stage and replaced or removed by a later one. The rule is one writer per
  series name.

## Constraints

- **Warm build budget.** A warm `nem_system` plus `build!(sim)` for one trading day (288 intervals)
  takes at most 20 s. The last measured warm `nem_system` took about 9.3 s; the model build has not
  been measured.
- **One trading day and one financial year per Simulation**, any length within them (C4). A
  read-only pre-flight check rejects anything else. `replay_batch.jl` already replays one trading
  day per run, and splits 30 June at the financial-year boundary.
- **PSI fork.** The fork stays pinned, and upstream is the reference for design decisions
  (`docs/psi-anatomy.md`). AEMSim must no longer use the fork's `TimeSeriesCostParameter` or its
  per-step cost targets.
- **NEM correctness.** Any change to a formulation, bound, cost term or constraint is checked
  against AEMO documentation during planning and again at review (AGENTS.md). G6 rests on the claim
  that band prices are fixed for a trading day and that rebids change quantities only, for energy,
  FCAS and MNSP. The ADR must record the NER and AEMO citation for it.
- **Typed-system rules** (ADR 0095, ADR 0097):
  - stock PSY devices, each carrying `NEMUnitData`;
  - series-key fields are `IS.StaticTimeSeriesKey`;
  - PSY component types that get serialised live in the top-level AEM module.
- **Units in checks.** Pre-flight checks read AEM natural-unit data only (`NEMUnitData`, raw series
  values), never PSY per-unit getters. `validate_template` runs before PSI forces `SYSTEM_BASE`, and
  `with_units_base` would be a System write.
- **Working rules.**
  - Run one Julia process at a time.
  - Format with Runic.
  - Every function ends in an explicit `return`.
  - Docstrings are reference documentation and do not cite ADRs.
  - Keep `CHANGELOG.md` current.
  - Record the decisions, and the departures from ADR 0095/0096/0098, in a new ADR.

## Decided design

### D1. Ownership: everything moves to AEM

Every write `prepare_replay!` performs today moves into AEM's
`nem_system(db, NEMDEConfiguration(); date_range)`.

| Today (AEMSim) | Moves to |
| --- | --- |
| `transform_single_time_series!` (`checks/replay_range.jl:13-22`) | AEM, at the end of `nem_system`. The `NEMDispatchProblem` constructor rejects non-default `horizon` and `interval`, so PSI's own auto-transform never adds a second forecast set |
| `energy_offer[_decremental]`, loss-factor referred and rounded (`offers/effective_offers.jl:334-352`) | AEM series |
| MNSP fixed-load value and invoked flag (`:273-293`) | AEM series, written once, with no later DSTS removal |
| ramp rates as the lesser of bid and telemetry (`:440-489`) | AEM series |
| AGC ramp rates (`:495-514`) | AEM series |
| state seeds `initial_mw_seed` and the fixed-load seeds (`:75-109`) | AEM observed-state series (D4) |
| FCAS effective trapeziums and ramping limits (`offers/fcas_effective.jl:567-611`) | AEM series (D4) |
| tie-break scales and the `EnergyTieBreak` service (`offers/tie_break.jl:149-179`) | AEM: the service built once, and the per-interval scales written once as a series |
| `loss_demand_coefficient` on `AreaInterchange` (`offers/loss_demand.jl:42-62`) | AEM series |
| `NEMDispatchInputs` attribute (`offers/effective_offers.jl:124-133`) | removed: series names are fixed `NEM_SERIES` constants passed through the fork's `add_parameters!(…; meta, time_series_name)` (R7). The private `_get_time_series_name` overrides go too |
| range checks taking `steps` (`checks/replay_range.jl:47-61`) | AEM enforces one trading day and one financial year on `date_range`. The replay range is the System range. Range-dependent checks run over the System's own range (R5) |

### D2. Scope: modelling choices in the template, data facts in AEM

- **Data fact.** "Constraint X is never invoked in this date range" is a fact about the data. AEM
  decides it when it builds the System for that range, and either leaves the constraint out or marks
  it unavailable as data, written once.
- **Modelling choice.** "Replay without these constraints" (user exclusions) is a `"filter_function"`
  attribute on the aggregated `ServiceModel(GenericConstraint, …)`. PSI's expansion honours it and
  carries attributes to the per-name models (R8). Nothing may depend on per-model
  `time_series_names` or feedforwards, which the expansion drops.
- **Template fact.** "This constraint involves something the template does not model" (no FCAS
  service model, no `AreaInterchange` model) is decided in `validate_template`, which deletes those
  per-name service models from the model's template copy, as PSI does for empty device models. It does
  not skip inside `construct_service!`, where dual and result read-back expect the containers. Reduced
  templates stay supported.
- **Report.** One pure predicate `(sys, template) -> rows` feeds both the pruning and the
  skipped-constraints report that `replay_batch_worker.jl` writes (C5).
- `exclude_unmodeled_services!`, its `ext` record and its rollback are removed.

### D3. State through PSI initial conditions

Every stateful quantity is a PSI initial condition:

| State | Initial condition |
| --- | --- |
| initial MW | AEMSim `NEMInitialPower <: InitialConditionType`, with its own value and update methods (R4). Stock `DevicePower` reads `OnVariable`, ignores storage In/Out and errors on limits |
| storage state of charge, once modelled | PSI's `InitialEnergyLevel` |
| fast-start dispatch mode and time in mode, once modelled | AEMSim `InitialConditionType`s, on the pattern of `InitialTimeDurationOn` |
| any other carried quantity (for example MNSP or interconnector flow, if it proves stateful) | as needed |

- **Closed loop.**
  - `requires_initialization` stays `false`, which avoids a second full model build and solve. The
    initial conditions are created in `construct_device!` and seeded from AEM's observed series.
    Step 1 uses those build-time values.
  - Each later step runs `update_parameters!` before `update_initial_conditions!`. The
    state-dependent parameters are therefore recomputed from the `SimulationState` argument
    (`get_system_state_value`), not from the initial-condition containers, which still hold the
    previous step (R3).
  - The initial conditions feed only the constraints that use initial MW itself.
  - These methods are written on the closed-loop problem type, so observed mode has no methods (R2).
- **Observed (`false`).** The state-dependent inputs are AEM-written series, refreshed by PSI's
  stock time-series update (G4).

### D4. One derivation library, in AEM, with two callers

The pure state-to-input rules move into AEM as scalar kernels:
`f(inputs::Float64…, state::NEMUnitState) -> Float64 | NTuple{N,Float64}`. A kernel takes no device,
no System, no series read, and no keyword-selected behaviour. AEM's writer loops the kernel over the
range, and callers convert units at the boundary (state is MW; PSI values are per unit). Today
`state_derivation.jl` already has this shape; `derivation.jl` and `fcas_effective.jl` need it (R11). They are now in
`…Simulations/src/offers/derivation.jl`, `state_derivation.jl` and `initial_state.jl`:

- `NEMUnitState`;
- composite storage ramps;
- FCAS enablement, stranding, scaling and ramping limits;
- fixed-load invoked;
- the MNSP ramp envelope.

AEM calls them on AEMO's observed state when it writes the D1 series. AEMSim's closed-loop updates
(milestone 2) call the same functions on initial-condition values. Parity between the two modes then
depends only on which state is fed in.

### D5. The closed-loop switch

The problem type passed to `DecisionModel` is the only switch (G5). PSI's per-step hooks see
`model::DecisionModel{M}` and never the template or its attributes. Closed-loop update and
initial-condition methods are therefore written on `DecisionModel{NEMClosedLoopDispatchProblem}`
with a concrete parameter type in the key. Observed mode has no such methods.

- `construct_device!` does not see the model. The constructor writes `ext["closed_loop"]::Bool` into
  the model settings, as `market_price_cap` is passed today. The C6 accessor reads it once per
  `construct_device!` call.
- Formulation types carry no mode parameter. That avoids compiling every `DeviceModel{D,B}`-specialised
  build method twice.

### D6. Prices are build-time constants; losses and FCAS slopes keep coefficient updates

This decision is G6 and G7, with the one-trading-day and one-financial-year constraint.

- AEMSim stops using `TimeSeriesCostParameter`, `add_cost_target!` and `_apply_cost_targets!`, which
  removes 12 key types.
- Band prices are typed per-day data written by AEM: an `NTuple{10,Float64}` on the offer struct in
  `NEMUnitData` and the MNSP and FCAS equivalents, already loss-factor referred and rounded. AEM
  throws at build if prices vary over `date_range`, which checks the real invariant (R6).
- AEMSim adds the terms with `PSI.add_to_objective_invariant_expression!` in `objective_function!`.
  There is no parameter, no `_unwrap_for_param` price method and no window read.
- **Invocation mask (R1).** The slack price was `invoked_t × CVP × MPC`. It becomes a constant
  `CVP × MPC` on the slack, plus an unpriced relaxation `c_t (r⁺ − r⁻)` on the row, with
  `c_t = 1 − invoked_t` as a `ConstraintCoefficientParameter` on `GenericConstraint`. Big-M RHS
  relaxation is rejected because it risks the 1e-9 match and the duals. This is a formulation change,
  so it needs an AEMO check and an ADR entry.

### D7. Code that goes

- the AEMSim functions `prepare_replay!`, `set_effective_offers!` and `exclude_unmodeled_services!`;
- all 10 per-step overrides, `_stock_state_update!`, `_FORCE_CUSTOM_STATE_UPDATES` and the test
  counters;
- `_step_cache`;
- the `StateSource` / `ObservedState` / `SimulatedState` dispatch;
- the `psi_compat.jl` shims that only served the removed paths.

The `state_update_equivalence` test is replaced by milestone 2's closed-loop tests.

## Calls I made (not confirmed by the user)

- **C1.** Withdrawn. The user chose the problem type as the switch (G5, D5).
- **C2. Never-invoked constraints** are a data fact decided by AEM (D2). Today they are an AEMSim
  pre-flight computation.
- **C4. Financial year.** The market price cap, and therefore the penalty prices, change at the
  financial-year boundary, which falls at midnight inside the 30 June trading day. So do the marginal
  loss factors. The rule is therefore within one trading day *and* one financial year, of any length
  (mock tests replay 2-3 intervals, and `--start` / `--intervals` stay). The batch keeps splitting
  30 June into two Simulations, each with its own System.
- **C5. Constraint exclusions by reason.**
  - Never invoked, `:missing_component` and `:no_available_device` are data facts. AEM decides
    them.
  - `:unmodeled_fcas_service` and `:unmodeled_device_type` depend on the template. The formulation
    skips those constraints at build.
  - Blocked constraints still throw, from `validate_template`.
  - The report is a read-only function, so the batch output format is unchanged.
- **C6. No initial conditions in milestone 1.** In observed mode, formulations declare no initial
  conditions and read initial MW (and the other state inputs) from AEM's series. This keeps the
  current `InterProblemChronology` from overwriting them with solved values. Each state input is
  reached through one accessor per quantity that branches on the settings' `closed_loop` at build. In milestone 2
  the `true` branch returns the initial-condition-backed value, so the constraints that use the
  value do not change. The accessor returns a `JuMP.AffExpr` for `(name, t)`, with one method per
  quantity. The mode is read once per `construct_device!` call and passed down as an argument (R10).
- **C7. Tie-break scales stay per step.** Correcting my earlier framing, they are not price-only.
  They keep their coefficient parameter, unchanged from today, so the 1e-9 baseline match is
  unaffected.
- **R-series.** R1 to R11 are the Fable design review's findings, adopted as written: R1 invocation
  mask, R2 mode carried in the problem type (user chose option B: the problem type is the switch), R3
  closed-loop updates read `SimulationState`, R4 `NEMInitialPower` without `requires_initialization`,
  R5 the replay range is the System range, R6 day-constant typed prices, R7 keep the fork's
  `add_parameters!` keywords, R8 the exclusion mechanisms, R9 natural units in checks, R10 the C6
  accessor returns `JuMP.AffExpr`, R11 scalar kernels.
- **C3. Acceptance tolerance** is the one previous tasks used: replay results identical to the
  baseline within 1e-9 absolute per variable, byte-identical in practice.

## Left to the builder

- the PSI mechanism for user exclusions (D2);
- whether `NEMDispatchInputs` survives (D1);
- whether the fork's `add_parameters!(…; meta, time_series_name)` keywords are still needed once
  series names are fixed;
- the migration order (one family at a time, as in the key-type work, is the expected shape);
- where the derivation functions sit in AEM's `src/`, following AGENTS.md's layout table;
- test layout, and which tests move between the root and Simulations suites.

## Acceptance (milestone 1)

1. **Baseline match.** Replay results match the `perf/key-types` baseline (`79162ba`) within the C3
   tolerance, on the generated mock fixtures and on one real trading day from `~/.nemdb_cache`.
2. **NEMDE comparison.** The full p5..p99 and max table is no worse than the baseline's.
3. **Build and step times.** A warm `nem_system` plus `build!(sim)` for one trading day takes at most
   20 s, measured and reported. Per-interval step time is no worse than the baseline.
4. **No writes, no custom updates.** A grep finds no System mutator in
   `AustralianElectricityMarketsSimulations/src/` (G1), and AEMSim defines no per-step update
   methods for the observed mode (G4).
5. **Closed-loop guard.** `DecisionModel(NEMClosedLoopDispatchProblem, template, sys)` fails in
   `validate_template` with the not-implemented message.
6. **Key types.** Net count reported. The expected count is about 115 (125 − 12 + 1 or 2).
7. **Serialisation.** A `NEMDEConfiguration` System round-trips through serialisation, or is
   documented as in-memory only.
8. **Suites and records.** The root and Simulations suites and Linting pass, the real-data
   integration suite has been run, a new ADR is written, and `CHANGELOG.md` is updated.
