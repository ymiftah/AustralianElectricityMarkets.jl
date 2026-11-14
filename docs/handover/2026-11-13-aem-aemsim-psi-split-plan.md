# AEM / AEMSim Split Along PowerSimulations' Design: Milestone 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every System write out of AEMSim into AEM's `nem_system`, leave AEMSim with PSI's stock per-step updates and build-time price constants, and make the replay interface exactly `nem_system` -> `DecisionModel` -> `Simulation`, with results matching the `perf/key-types` baseline (79162ba) within 1e-9.

**Architecture:** AEM gains a private builder stage `_set_replay_inputs!(sys)` that `nem_system(db, NEMDEConfiguration(); date_range)` runs last. Families of derived inputs move into it one at a time, each as a scalar kernel in `src/derivations/` plus a writer in `src/system/replay_inputs/`, while the matching AEMSim writer is deleted in the same commit. Once the stage holds everything (including the forecast transform), `prepare_replay!` is removed, checks move into `validate_template`, prices become typed day-constants in the invariant objective, and two problem types select the mode.

**Tech Stack:** Julia 1.13 workspace (AEM root package, `AustralianElectricityMarketsSimulations`), PowerSystems.jl, pinned PowerSimulations fork (`/home/simba/.julia/dev/PowerSimulations.jl-fork`), JuMP, HiGHS, DuckDB, Runic.

**Spec:** `/home/simba/.julia/dev/AustralianElectricityMarkets/.claude/worktrees/docs-psi-anatomy/docs/superpowers/specs/2026-11-13-aem-aemsim-psi-split-design.md` (source of truth: G1-G7, D1-D7, C2-C7, R1-R11 are settled). Background map: `docs/psi-anatomy.md` (same worktree).

## Global Constraints

Machine-local rules (every executor and reviewer follows them):

- **One Julia process at a time**, across all agents (14 GB machine). Never run two captures, suites or precompiles concurrently.
- After editing any `src/`, **precompile alone first**: `JULIA_NUM_PRECOMPILE_TASKS=1 julia --heap-size-hint=4G --project=AustralianElectricityMarketsSimulations/test -e 'using Pkg; Pkg.precompile()'`.
- kaimon (Julia MCP) is preferred but currently unavailable: use plain `julia` from the shell.
- Run **only the test groups a task names**. Full suites run only at checkpoints CP1, CP2 and Task 22.
- Real-data runs and all their outputs go under `/run/media/simba/Store/aem_validation/YYYY-MM-DD_<kind>_<topic>_<commit7>/` (`<kind>` in `replay`, `batch`, `bench`, `profile`, `compare`), each with `README.md` and `run.log`. Check `mountpoint -q /run/media/simba/Store`; mount with `udisksctl mount -b /dev/nvme0n1p1`. Never fall back to another location.
- Worktree: `/home/simba/.julia/dev/AustralianElectricityMarkets/.worktrees/refactor-psi-split`, branch `refactor/psi-split`, created from `docs/psi-anatomy` (490e6dc; code identical to 79162ba). All commands below run from that root. Use absolute paths in backgrounded shells.
- Plans and specs under `docs/superpowers/` are gitignored and never committed.
- Runic formatting (`pre-commit run -a` at the end of each task). Every function ends in an explicit `return`. Docstrings are reference documentation (signature, short prose, `# Arguments`, `# Returns`) and never cite an ADR. Comments are one or two lines. No em-dashes in prose. Keep `CHANGELOG.md` `## [Unreleased]` current in every task that changes behaviour or API.
- **NEM correctness:** any task marked **[AEMO]** loads the `nem-expert` skill (`~/.agents/skills/nem-expert/`) during implementation and again at review, and records the AEMO or NER citation for every bound, constraint and cost term it touches in the commit body and in ADR 0101 (Task 21). Departures from AEMO go in the ADR. Tasks marked **[move]** carry existing AEMO citations over verbatim; the reviewer confirms none was lost.
- No silent fallbacks for missing cache columns or tables; the remedy message is `populate(...; force_new = true)`.
- One writer per series name. No series written by one stage and replaced or removed by a later one.
- Serialised PSY types live in the top-level `AustralianElectricityMarkets` module. Series-key fields are `IS.StaticTimeSeriesKey`.
- Unused exports may be deleted (no public API consumers; the litmus is `scripts/replay_batch.jl`).

Spec values copied verbatim:

- Baseline tolerance: 1e-9 absolute per variable.
- Warm `nem_system` + `build!(sim)` for one trading day (288 intervals): at most 20 s.
- Key types: baseline 125 (mock), expected about 115.
- Closed-loop guard message: `closed-loop replay is not implemented`.
- A NEMDE System covers one trading day and one financial year.

**Execution model:** each task is implemented by a **Haiku** subagent from a step-by-step brief the controller writes from this plan (exact files, names and commands included), then reviewed by an **Opus** subagent. **[AEMO]** tasks get the NEM correctness check in both passes. A task is done when its tests pass, the gate passes and the review is clean. Rollback point for every task: the previous task's commit (`git revert` the task's commits; never rewrite earlier tasks).

### Shared commands

```bash
T=AustralianElectricityMarketsSimulations/test
PRECOMPILE='JULIA_NUM_PRECOMPILE_TASKS=1 julia --heap-size-hint=4G --project=AustralianElectricityMarketsSimulations/test -e "using Pkg; Pkg.precompile()"'
# Root groups:
julia --heap-size-hint=4G --project=. -e 'using Pkg; Pkg.test(; test_args = ["<group>", "<group>"])'
# Simulations groups:
julia --heap-size-hint=4G --project=$T $T/runtests.jl <group> <group>
```

**GATE(NN)** (run on the task's commit, clean tree, commands strictly in sequence):

```bash
mountpoint -q /run/media/simba/Store || udisksctl mount -b /dev/nvme0n1p1
B=/run/media/simba/Store/aem_validation/2026-11-13_compare_psi-split-baseline_79162ba
C=/run/media/simba/Store/aem_validation/$(date +%F)_compare_psi-split-task${NN}_$(git rev-parse --short HEAD)
julia --heap-size-hint=4G --project=$T $T/baseline/capture.jl --hive mock --start 2025-01-01T00:05:00 --intervals 3 --out $C/mock
julia --heap-size-hint=4G --project=$T $T/baseline/capture.jl --hive $HOME/.nemdb_cache --start 2026-06-04T04:05:00 --intervals 12 --out $C/real_1h
julia --project=$T $T/baseline/compare.jl $B/mock $C/mock $GATE_FLAGS
julia --project=$T $T/baseline/compare.jl $B/real_1h $C/real_1h $GATE_FLAGS
```

Expected: both compares print `GATE PASS` and exit 0. `GATE_FLAGS` is empty through Task 14 and is `--mask-gc-slacks --allow-new GenericConstraintRelaxation` from Task 15 on.

**CHECKPOINT(label)** (CP1 after Task 14, CP2 after Task 18, final in Task 22): GATE, then

```bash
julia --heap-size-hint=4G --project=$T $T/baseline/capture.jl --hive $HOME/.nemdb_cache --start 2026-06-04T04:05:00 --intervals 288 --warm --out $C/real_day
julia --project=$T $T/baseline/compare.jl $B/real_day $C/real_day $GATE_FLAGS
O=/run/media/simba/Store/aem_validation/$(date +%F)_batch_psi-split-${label}_$(git rev-parse --short HEAD)
julia --heap-size-hint=4G --project=$T scripts/replay_batch.jl --first 2026-06-04 --last 2026-06-04 --hours 3 --hive $HOME/.nemdb_cache --output $O
python3 scripts/simulation_statistics.py $O
```

then the full root and Simulations suites. Expected: `GATE PASS`; `$O/simulation_statistics/errors.csv` no worse than the baseline's in any p5..p99 or max cell; `skipped_constraints.csv` identical to the baseline's (`diff`).

## Decisions this plan makes (left to the builder by the spec)

| Open item | Decision |
| --- | --- |
| Where derivations sit in AEM | Kernels in new `src/derivations/` (one file per family). Writers in new `src/system/replay_inputs/` (one file per family), orchestrated by `src/system/replay_inputs.jl`. `NEMUnitState` in `src/types/unit_state.jl`. |
| AEM entry for derived inputs | One private stage `AustralianElectricityMarkets._set_replay_inputs!(sys::PSY.System) -> Nothing`, called by `nem_system` just before `_check_nemde_replay_inputs`. Hand-built test fixtures call it as their last builder step. AEMSim never calls it. It writes with `add_time_series!` (write once), so a second call throws. |
| Replay intervals of a System | Every caller builds `date_range = first(steps):5min:(last(steps) + 10min)`. The replay intervals are `date_range[1:(end - 2)]`, which equal the System's forecast initial times less the last. AEM exports `replay_intervals(sys) -> Vector{DateTime}`. C4 and R6 are enforced over the replay intervals only (the two trailing stamps may fall in the next trading day or financial year). `nem_system(NEMDEConfiguration)` requires `length(date_range) >= 3`. |
| `NEMDispatchInputs` | Removed, with `NEMFCASInputs`. Formulations pass fixed AEM name constants. |
| Fork `add_parameters!(…; meta, time_series_name)` keywords | Kept (R7): one parameter type still serves several series. |
| User exclusions (D2) | `template_nemde(; exclude_constraints::AbstractDict{<:AbstractString, Symbol} = Dict{String, Symbol}())` sets two attributes on the aggregated `ServiceModel(GenericConstraint, LinearFactorLimit)`: `"filter_function" => gc -> !haskey(exclude_constraints, PSY.get_name(gc))` and `"excluded_constraints" => Dict{String, Symbol}(exclude_constraints)`. |
| Never-invoked and no-available-device constraints (C2, C5) | AEM builds them with `available = false` and records them in `NEMBuildReport.unavailable_constraints`. Precedence: `never_invoked` (over the replay intervals) before `no_available_device`, as the baseline reports them. `:missing_component` stays a throw: AEM's build already rejects it, and `validate_template` treats it as blocking. |
| Skipped-constraints predicate | `replay_skipped_constraints(sys, template) -> DataFrame` (columns `constraint`, `reason`, `n_missing`, sorted by `constraint`), pure, in `…Simulations/src/checks/nem_constraints.jl`. Feeds pruning and the batch report. |
| Invocation mask series (R1) | No new series. `GenericConstraintInvocationMaskParameter <: PSI.ConstraintCoefficientParameter` reads `NEM_CONSTRAINT_SERIES.invoked` and a `PSI._unwrap_for_param` method returns `1.0 - v`. Relaxation is one variable type `GenericConstraintRelaxation` holding `r⁺` and `r⁻` (axes name, `("up", "down")`, time). Relaxation is added only where slacks are added today (`use_slacks`), so the no-slack behaviour is unchanged. |
| Typed prices (R6) | `band_prices::Union{Nothing, NTuple{10, Float64}}` on `NEMEnergyBid`, `NEMFCASBid` and `NEMMNSPBid`, `nothing` until `_set_replay_inputs!` fills it (regional systems leave it `nothing`). Energy prices are referred and rounded. Shorter curves pad with `0.0`. |
| `energy_offer` series after prices are typed | Kept, read for band widths only. Dropping it (reading widths from the raw bid series) is the first lever if the 20 s budget fails in Task 22, and otherwise a follow-up. |
| C6 accessors | Two quantities carry raw state: unit initial MW and MNSP initial flow. One accessor each, `(container, …, name, t, closed_loop::Bool) -> JuMP.AffExpr`. Fixed loads, ramps and FCAS limits are state-dependent parameters in both modes and need no accessor. |
| Kernel units (D4) | Kernels take MW and natural units. Writers divide by the system base at the boundary. Display units are never toggled. |
| Series name strings | Unchanged (`"initial_mw_seed"`, `"fixed_load_seed"`, …), so the snapshot keys stay comparable. The constants move to AEM. |
| Test layout | Kernel and writer tests live in the root suite under `test/replay_inputs/` (one new root group per family, named in each task). Formulation and replay tests stay in the Simulations suite. |
| Per-task real gate | A 12-interval real range per task; the full real trading day only at checkpoints. |

## File Structure

| Path | Change | Responsibility |
| --- | --- | --- |
| `…Simulations/test/baseline/snapshot.jl`, `capture.jl`, `compare.jl` | create | Baseline snapshot, metrics and the 1e-9 gate |
| `src/types/unit_state.jl` | create | `NEMUnitState` |
| `src/derivations/{state,energy,ramps,fcas,tie_break,loss_demand}.jl` | create | Scalar kernels (D4) |
| `src/system/replay_inputs.jl` | create | `_set_replay_inputs!`, `replay_intervals`, range rules |
| `src/system/replay_inputs/{common,energy_offers,mnsp_fixed_loads,dispatch_limits,state_inputs,fcas_effective,tie_break,loss_demand,constraints,prices,forecasts}.jl` | create | One writer per family |
| `src/accessors/series_names.jl` | modify | Name constants moved from AEMSim |
| `src/types/{nem_offer_cost,network_data,build_report}.jl` | modify | `band_prices` fields; `unavailable_constraints` |
| `src/system/nemde.jl`, `src/system/mnsp.jl` | modify | Call the stage; range checks; MNSP curves keep all bands |
| `…Simulations/src/offers/*`, `…/offers/state_updates/*` | delete over the plan | Writers, derivations, per-step overrides |
| `…Simulations/src/checks/{replay_range,replication_steps,financial_year,tie_break}.jl` | delete | Replaced by AEM rules and `validate_template` |
| `…Simulations/src/checks/nem_constraints.jl`, `template.jl`, `dispatch_envelope.jl` | modify | Predicate, pruning, System-range checks |
| `…Simulations/src/problems/nem_dispatch.jl` | modify | Two problem types, guard, `closed_loop` setting |
| `…Simulations/src/formulations/*.jl` | modify | Fixed names, invariant price terms, mask, accessors |
| `scripts/replay_batch_worker.jl`, `…Simulations/src/precompile.jl`, `docs/literate/tutorials/nemde_aem.jl` | modify | G3 interface |
| `docs/adr/0101-aem-writes-aemsim-reads.md` | create | Decisions, citations, departures from ADR 0095/0096/0098 |

## Review Focus

1. **A `date_range` whose replay intervals cross 04:00 or 00:00 on 1 July.** Expected: `nem_system` throws an `ArgumentError` naming the boundary; the two trailing stamps may cross it. Test in Task 12.
2. **A unit whose band prices differ between two replay intervals** (bad cache or a hand-built system). Expected: `nem_system` throws naming the DUID and market, never prices the day at the first interval's bands. Tests in Tasks 16-18.
3. **A reduced template** (no `FCASService` model, or no `AreaInterchange` model). Expected: affected constraints are pruned from the model's template copy and reported; the build is `BUILT`; result readers do not fail on constraints that are available in the System but not modelled. Test in Task 14.
4. **A file-backed System** (`time_series_in_memory = false`, the batch default) **and a second model built on the same System.** Expected: the forecast transform inside `nem_system` works on the HDF5 store; a second `DecisionModel` + `build!` on the same System succeeds and leaves `PSY.get_time_series_counts(sys)` unchanged. Tests in Tasks 12 and 14.
5. **A constraint invoked at some intervals only.** Expected: at a non-invoked interval the row does not bind, its slacks are zero and its dual is zero; at an invoked interval a violated row pays `CVP × MPC`. Test in Task 15.

---

### Task 0: Worktree, baseline tooling and baseline capture

**Files:**

- Create: `AustralianElectricityMarketsSimulations/test/baseline/snapshot.jl`, `capture.jl`, `compare.jl`, `AustralianElectricityMarketsSimulations/test/baseline_tools.jl`
- Modify: `AustralianElectricityMarketsSimulations/test/runtests.jl` (add group `"baseline_tools" => ("Baseline tools", "baseline_tools.jl")`)

**Interfaces (produced):**

- `replay_snapshot(results, sys) -> Dict{String, DataFrame}`: keys `"variable/<key>"`, `"dual/<key>"`, `"aux/<key>"`, `"expression/<key>"`, `"parameter/<key>"` (from `PSI.read_realized_*`, key strings from `PSI.IS.Optimization.encode_key_as_string`), `"stats/optimizer"` (`PSI.read_optimizer_stats`), and `"input/constraint_invoked"` (one row per replay interval, one column per `GenericConstraint` name, read from the `invoked` series).
- `compare_snapshots(baseline, candidate; atol = 1.0e-9, allow_new = Regex[], allow_missing = Regex[], mask_gc_slacks = false) -> Vector{NamedTuple}` (mismatch rows `key`, `kind`, `max_abs`). Gating kinds: `variable`, `dual`, `aux`, `expression`, and `objective_value` in `stats` (relative 1e-9). `parameter/…` differences are reported, never gating. Rows align on the non-numeric columns after sorting. A baseline key absent from the candidate, or a candidate key absent from the baseline, is a mismatch unless a regex allows it. `mask_gc_slacks` multiplies `GenericConstraintSlackUp/Down` values by `input/constraint_invoked` on both sides before comparing.
- `key_type_count(model) -> Int`: `length(unique(typeof, keys))` over the container's variables, parameters, constraints, expressions, aux variables, duals and initial conditions.
- `capture.jl --hive <mock|PATH> --start <ISO DateTime> --intervals <N> --out <DIR> [--warm]`: builds the System over `start:5min:(start + (N + 1) * 5min)`, runs the replay through the PSI interface, and writes `snapshot.jls` (`Serialization`), `metrics.toml`, `skipped_constraints.csv`, `comparison_summary.csv` (`comparison_summary(compare_intervals(read_published_interval(db, steps), read_solved_interval(results, sys)))`), `README.md` (purpose, command, branch, commit, dirty or clean, range, solver options, one-line outcome), `run.log` and the simulation folder `sim/`. `--hive mock` creates `create_mock_data(mktempdir(); complete_inputs = true)` plus `write_mock_interconnector_results`. It works on every commit of this plan: it calls `AEMS.prepare_replay!(sys, template, steps)` only `if isdefined(AEMS, :prepare_replay!)`, else `AEMS.replay_skipped_constraints(sys, template)`.
  Optimizer: `nemde_optimizer()`. `metrics.toml` fields: `commit`, `n_intervals`, `key_type_count`, `system_build_s`, `prepare_s`, `model_build_s`, `execute_s`, `execute_s_per_interval`, `timed_solve_p50`, `timed_solve_p95`, `timed_solve_max`; with `--warm` the build is repeated in-process and `warm_system_build_s`, `warm_prepare_s`, `warm_model_build_s` are added.
- `compare.jl <BASELINE_DIR> <CANDIDATE_DIR> [--atol X] [--allow-new REGEX]… [--allow-missing REGEX]… [--mask-gc-slacks]`: prints `GATE PASS max|Δ|=<x>` and exits 0, or prints the ten worst keys and exits 1; always prints the largest `parameter/` difference.

- [ ] **Step 1:** Create the worktree with `superpowers:using-git-worktrees`: `git worktree add /home/simba/.julia/dev/AustralianElectricityMarkets/.worktrees/refactor-psi-split -b refactor/psi-split docs/psi-anatomy`. Verify `git diff --stat 79162ba HEAD -- src AustralianElectricityMarketsSimulations scripts test` is empty.
- [ ] **Step 2: Write the failing tests** in `baseline_tools.jl` on synthetic `Dict{String, DataFrame}` inputs:

```julia
a = Dict("variable/x" => DataFrame(DateTime = [t1, t2], u = [1.0, 2.0]))
@test isempty(compare_snapshots(a, deepcopy(a)))
b = deepcopy(a); b["variable/x"].u[2] += 2.0e-9
@test only(compare_snapshots(a, b)).key == "variable/x"
b = deepcopy(a); b["variable/x"].u[2] += 5.0e-10
@test isempty(compare_snapshots(a, b))
c = merge(a, Dict("variable/new" => a["variable/x"]))
@test !isempty(compare_snapshots(a, c))
@test isempty(compare_snapshots(a, c; allow_new = [r"new"]))
@test !isempty(compare_snapshots(c, a))
p = merge(a, Dict("parameter/p" => DataFrame(DateTime = [t1], u = [1.0])))
q = deepcopy(p); q["parameter/p"].u[1] = 9.0
@test isempty(compare_snapshots(p, q))
```

plus one `mask_gc_slacks` case: two snapshots whose `GenericConstraintSlackUp` values differ only where `input/constraint_invoked` is `0.0` compare equal with the mask and unequal without.

- [ ] **Step 3:** Run `julia --project=$T $T/runtests.jl baseline_tools`. Expected: FAIL, `compare_snapshots` not defined.
- [ ] **Step 4:** Implement `snapshot.jl`, `capture.jl`, `compare.jl`. Run the group again. Expected: PASS.
- [ ] **Step 5:** Commit (`test: add replay baseline capture and comparison tools`).
- [ ] **Step 6: Capture the baseline** into `B=/run/media/simba/Store/aem_validation/2026-11-13_compare_psi-split-baseline_79162ba`: `capture.jl` for `mock` (3 intervals from `2025-01-01T00:05:00`), `real_1h` (12 intervals from `2026-06-04T04:05:00`) and `real_day` (288 intervals, `--warm`). If the mock hive does not cover 3 intervals, use 2 and change GATE to match. If the real cache does not cover the day, stop and ask the user (do not populate, do not pick another day silently).
- [ ] **Step 7: Determinism check.** Capture `mock` a second time into `$B/mock_repeat`; `compare.jl $B/mock $B/mock_repeat --atol 0`. Expected: `GATE PASS max|Δ|=0.0`. If it fails, stop: the gate is not usable until the cause is found.
- [ ] **Step 8: Batch baseline.** Run the CHECKPOINT batch commands into `/run/media/simba/Store/aem_validation/2026-11-13_batch_psi-split-baseline_79162ba`. Copy `simulation_statistics/errors.csv`, `timing_percentiles.csv` and `2026-06-04/skipped_constraints.csv` paths into `$B/README.md`.
- [ ] **Step 9: Record in `$B/README.md`:** the p5..p99 and max error table; `warm_system_build_s`, `warm_prepare_s`, `warm_model_build_s` and their sum for the real day; per-interval `parameter_update` and `solve_and_write` percentiles; `key_type_count` for mock and real (expected 125 and 129; if the mock count is not 125, align `key_type_count` with ADR 0100's method before going on); the list of parameter keys in the mock model, as a table of which families the mock gate exercises (batteries, MNSP, FCAS, tie-break, fixed loads, generic constraints).
- [ ] **Step 10: Price probe.** With a throwaway script in the session scratchpad, on the `real_day` and `mock` Systems, check for every energy bid, FCAS bid and MNSP offer curve series whether the padded y-coordinates are equal across the replay intervals. Record the three results in `$B/README.md` under "Price constancy". Expected: energy and FCAS constant (their curves keep empty bands); MNSP may vary by band position because `_mnsp_offer_curve` (`src/system/mnsp.jl:185`) drops empty bands. Task 18 depends on this finding. If energy or FCAS vary on real data, stop and report to the user: G6 does not hold as built.

**Risks:** `PSI.read_realized_*` return shapes differ by kind (wide or long); the comparison must align on names, not positions. The gate proves nothing for a family the mock model lacks; Step 9's table says which families rely on `real_1h`.

---

### Task 1: AEM home for state, kernels and the builder stage

**Files:**

- Create: `src/types/unit_state.jl`, `src/derivations/state.jl`, `src/system/replay_inputs.jl`, `src/system/replay_inputs/common.jl`, `test/replay_inputs/stage.jl`
- Modify: `src/AustralianElectricityMarkets.jl` (includes, exports), `src/system/nemde.jl:95-98` (call the stage before `_check_nemde_replay_inputs`), `test/runtests.jl` (group `"replay_inputs_stage"`), `…Simulations/src/AustralianElectricityMarketsSimulations.jl` (import the moved names, drop `include("offers/state_derivation.jl")`), `…Simulations/src/types/state.jl` (delete the `NEMUnitState` struct), hand-built fixtures in `…Simulations/test/toy_fixture.jl`, `test/integration/pscb_fixture.jl` and any other fixture that calls `set_effective_offers!` or `prepare_replay!` on a System not built by `nem_system` (find with `grep -rn 'set_effective_offers!\|prepare_replay!' AustralianElectricityMarketsSimulations/test test`)
- Delete: `…Simulations/src/offers/state_derivation.jl`

**Interfaces (produced):**

- `AustralianElectricityMarkets.NEMUnitState(initial_mw::Float64, dispatch_mode::Int)`, exported.
- Exported, moved verbatim: `max_active_power_floor`, `in_fast_start_profile`, `fixed_load_invoked`, `effective_fixed_load`, `fcas_state_stranded_ok`, `fcas_both_sides_stranded_ok`, `fcas_ramping_active`, `fcas_joint_ramping_exempt`, `fcas_ramping_limit`, `mnsp_ramp_envelope`, `composite_ramp_rates`.
- `AustralianElectricityMarkets._set_replay_inputs!(sys::PSY.System) -> Nothing`: empty body for now. Each later task appends one writer call, in this fixed order: energy offers, MNSP fixed loads, dispatch limits, state inputs, FCAS effective, tie-break, loss demand, constraint availability, prices, forecasts.
- `AustralianElectricityMarkets._replay_interval_stamps(sys::PSY.System) -> Vector{DateTime}`: from `PSY.check_time_series_consistency(sys, PSY.SingleTimeSeries)` `(initial, n)`, the stamps `initial .+ (0:(n - 2)) .* Minute(5)`. Used by writers before the transform.

- [ ] **Step 1: Failing root test** `test/replay_inputs/stage.jl`: `NEMUnitState(10.0, 0).initial_mw == 10.0`; `composite_ramp_rates` and `fixed_load_invoked` are callable from `AustralianElectricityMarkets` with the argument values the existing Simulations `state.jl` tests use (copy two assertions each); for `sys = nem_system(db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(20)))` on the mock hive, `AustralianElectricityMarkets._replay_interval_stamps(sys) == collect(t:Minute(5):(t + Minute(10)))`.
- [ ] **Step 2:** Run root group `replay_inputs_stage`. Expected: FAIL (`NEMUnitState` not defined in AEM).
- [ ] **Step 3:** Move the struct and `state_derivation.jl` to AEM unchanged; add the stage and its call; AEMSim imports the names with `using AustralianElectricityMarkets: NEMUnitState, …` and keeps exporting none of them.
- [ ] **Step 4:** In each hand-built fixture, call `AustralianElectricityMarkets._set_replay_inputs!(sys)` as the last builder statement (a no-op today).
- [ ] **Step 5:** Precompile. Run root `replay_inputs_stage`, `package_boundaries`; Simulations `state`, `nem_dispatch_toy`, `fcas_preprocessing`. Expected: PASS.
- [ ] **Step 6:** GATE(01). Runic, CHANGELOG, commit.

**Risks:** `IS.get_module` resolves only top-level names, so `NEMUnitState` must be defined in the top-level module, not a submodule. A test that edits a hand-built System after the fixture returns will read stale derived inputs once families migrate; each family task greps for such edits.

---

### Task 2: Delete the custom per-step branch (D7, G4)

**Files:**

- Delete: `…Simulations/src/offers/state_updates.jl`, `…/offers/state_updates/fcas.jl`, `…/offers/state_updates/mnsp.jl`, `…Simulations/test/state_update_equivalence.jl`
- Modify: `…/offers/state_updates/energy.jl` (keep only `_fixed_load_mw`, `_fixed_load_step`, `_fixed_load_mw_series`, `_fixed_load_step_series`; move them into `…/offers/effective_offers.jl` and delete the file), `…Simulations/src/psi_compat.jl:126-197` (delete `_psi_set_param_value_at!`, `_psi_apply_coefficient_targets!`, both `_stock_state_update!`), `…Simulations/src/types/state.jl` (delete `SimulatedState`, `_precomputes_state_inputs`, `_FORCE_CUSTOM_STATE_UPDATES`; keep `ObservedState` and `unit_state` until Task 6), `…Simulations/src/offers/fcas_effective.jl` (delete `_FCAS_EVALUATIONS`), module includes and exports, `…Simulations/test/runtests.jl` (drop group `state_update_equivalence`), `…Simulations/test/psi_compat.jl`, `…Simulations/test/template_helpers.jl` (`_update_step_parameters!` stays; it calls PSI's own method)

- [ ] **Step 1: Failing test** in `…Simulations/test/psi_compat.jl`:

```julia
@testset "no per-step update methods" begin
    for f in (PSI.update_container_parameter_values!, PSI.update_parameter_values!, PSI._update_parameter_values!)
        @test all(m -> parentmodule(m) !== AEMS, methods(f))
    end
end
```

- [ ] **Step 2:** Run Simulations group `psi_compat`. Expected: FAIL (10 methods in AEMSim).
- [ ] **Step 3:** Delete the 10 `PSI.update_container_parameter_values!` methods (`state_updates.jl:122`; `energy.jl:59,171,205`; `fcas.jl:111,141,171,202,235`; `mnsp.jl:47`), `_step_cache`, `_StepCache`, `_CUSTOM_STATE_UPDATE_CALLS`, `_use_stock_state_update` and every helper only they call (`grep` each name before deleting).
- [ ] **Step 4:** Precompile. Run Simulations `psi_compat`, `state`, `stock_simulation`, `recurrent_objective_cache`, `replay_workflow`. Expected: PASS.
- [ ] **Step 5:** Run `grep -rnE 'function PSI\.(update_container_parameter_values!|update_parameter_values!|_update_parameter_values!)|^PSI\.(update_container_parameter_values!|update_parameter_values!|_update_parameter_values!)\(' AustralianElectricityMarketsSimulations/src`. Expected: no output.
- [ ] **Step 6:** GATE(02). Runic, CHANGELOG, commit.

**Risks:** the overrides forwarded with `invoke` to two abstract fork methods (`ParameterKey{<:ConstraintCoefficientParameter, <:PSY.Component}` and `ParameterKey{<:ParameterType, <:PSY.Component}`). After deletion PSI's own dispatch must land on the same methods; a more specific fork method for one of the ten keys would change behaviour. The gate (3 and 12 stepped intervals) is the proof. This task comes first so later tasks do not have to keep dead callers of the derivations compiling.

---

### Family migration recipe (Tasks 3-10)

Each family task runs these steps with its own table:

- [ ] **R1: Failing root tests** in `test/replay_inputs/<family>.jl` (new root group `replay_inputs_<family>`): kernel assertions with exact values, and a writer assertion that a System from `nem_system(db, NEMDEConfiguration(); date_range)` on the mock replay hive (`create_mock_data(dir; complete_inputs = true)`), **with AEMSim not loaded**, carries the named series with the expected values computed in the test from the raw bid, telemetry and observed series.
- [ ] **R2:** Run the root group. Expected: FAIL (kernel undefined or series absent).
- [ ] **R3:** Implement the kernel(s) in `src/derivations/` and the writer in `src/system/replay_inputs/`; append the writer call to `_set_replay_inputs!` at its fixed position; move the family's name constants into `src/accessors/series_names.jl`. Shared readers (`_bid_series`, `_aligned_values`, `_grid_values`, `_energy_bid`, `_loss_factor`, `_bidding_devices`) are copied into `src/system/replay_inputs/common.jl` on first use (prefer an existing AEM accessor when it returns identical values); the AEMSim copy is deleted when its last AEMSim caller goes. Writers use `add_time_series!` through `single_series`, never `replace_single_series!`.
- [ ] **R4:** Delete the AEMSim writer and its call in `set_effective_offers!`; point the AEMSim reader at the AEM constant.
- [ ] **R5:** Move the family's writer tests out of `…Simulations/test/effective_offers.jl` (and `state.jl`, `fcas_preprocessing.jl` where named) into the root file. Keep formulation tests in Simulations. Grep the Simulations tests for edits to this family's raw inputs made after a fixture returns and move those edits before `_set_replay_inputs!`.
- [ ] **R6:** Precompile; run the root group and the Simulations groups in the table. Expected: PASS.
- [ ] **R7:** GATE(NN). Expected: `GATE PASS`, and the largest `parameter/` difference printed is `0.0` unless the table says otherwise.
- [ ] **R8:** Runic, CHANGELOG, commit.

### Task 3: Energy offer curves [move]

| Item | Value |
| --- | --- |
| Old | `_set_static_offers!`, `_set_energy_offers!`, `_check_fcas_bid_sides`, `referred_offer_curves` (`…/offers/effective_offers.jl:334-378`, `…/offers/derivation.jl`) |
| Kernel | `referred_price(price::Float64, loss_factor::Float64)::Float64 = round(price / loss_factor; digits = 2)` in `src/derivations/energy.jl` |
| Writer | `_set_referred_energy_offers!(sys)` in `src/system/replay_inputs/energy_offers.jl`: series `energy_offer_series_name(side)`, same x-coordinates, y-coordinates through the kernel. `_check_fcas_bid_sides(sys)` moves with it and runs first. |
| Kernel test | `referred_price(100.0, 0.97) == 103.09`; `referred_price(-1000.0, 1.0312) == -969.74` |
| Groups | root `replay_inputs_energy`, `market_bids`; Simulations `effective_offers`, `energy_offer_violations`, `nem_dispatch` |
| Risk | The loss factor is `load_loss_factor` on the `LOAD` side and `gen_loss_factor` otherwise; a swap passes mock data if both are 1.0, so the writer test uses a unit with distinct factors. |

### Task 4: MNSP fixed loads [move]

| Item | Value |
| --- | --- |
| Old | `_set_mnsp_fixed_loads!` (`…/offers/effective_offers.jl:273-293`), `NEM_MNSP_FIXED_LOAD_SERIES` (`…/types/mnsp_limits.jl`) |
| Kernel | `mnsp_fixed_load(raw::Float64)::NTuple{2, Float64}`: `(0.0, 0.0)` for `NaN`, else `(raw, 1.0)`, in `src/derivations/state.jl` |
| Writer | `_set_mnsp_fixed_loads!(sys)` in `src/system/replay_inputs/mnsp_fixed_loads.jl`: the four `NEM_MNSP_FIXED_LOAD_SERIES` series, written once, with no `DeterministicSingleTimeSeries` removal |
| Kernel test | `mnsp_fixed_load(NaN) == (0.0, 0.0)`; `mnsp_fixed_load(0.0) == (0.0, 1.0)`; `mnsp_fixed_load(-120.0) == (-120.0, 1.0)` |
| Groups | root `replay_inputs_mnsp`, `mnsp`; Simulations `mnsp_limits`, `interconnector_losses` |
| Risk | A bid with no `fixed_load` writes zeros on the `max_avail` grid; keep that branch. The mock gate may hold no MNSP (see Task 0 Step 9); `real_1h` covers it. |

### Task 5: Ramp rates and AGC ramp rates [move]

| Item | Value |
| --- | --- |
| Old | `_set_dispatch_limits!`, `_effective_ramp_rates`, `_set_agc_ramp_rates!`, `_bid_ramp_rates`, `_regulation_bid_max_avail`, `_regulation_availability` (`…/offers/effective_offers.jl:403-514`); `effective_ramp_limit`, `effective_ramp_limits`, `effective_regulation_max_avail`, `_agc_ramp_rate`, `effective_energy_availability` (`…/offers/derivation.jl`) |
| Kernels | In `src/derivations/ramps.jl`, scalar only: `effective_ramp_limit(bid_mw_per_min::Float64, telemetry_mw_per_h::Float64)::Float64`; `effective_regulation_max_avail(bid_max_avail::Float64, telemetry_max_avail::Float64)::Float64` (`NaN` bid means absent; no `nothing` argument); `agc_ramp_rate(ramp_rate::Float64, availability::Float64, interval_hours::Float64)::Float64`. The vector forms `effective_ramp_limits` and `effective_energy_availability` are deleted (the writer loops; grep first: `effective_energy_availability` has no writer caller). `composite_ramp_rates` is already in AEM. |
| Writer | `_set_dispatch_limits!(sys)` in `src/system/replay_inputs/dispatch_limits.jl`: `NEM_SERIES.ramp_up_rate`, `NEM_SERIES.ramp_down_rate`, `fcas_series_name("fcas_agc_ramp_rate", service)`. Same arithmetic order as today: `effective ./ 60 ./ base`, `NaN => 0.0`, zeros for a non-scheduled load. |
| Kernel test | `effective_ramp_limit(5.0, 240.0) == 240.0`; `effective_ramp_limit(3.0, 240.0) == 180.0`; `effective_ramp_limit(NaN, 240.0) == 240.0`; `isnan(effective_ramp_limit(3.0, NaN))`; `agc_ramp_rate(1.2, 0.05, 1 / 12) == 1.2`; `agc_ramp_rate(0.2, 0.05, 1 / 12) == 0.05 / (1 / 12)` |
| Groups | root `replay_inputs_ramps`; Simulations `effective_offers`, `nem_dispatch`, `storage_availability`, `fcas_preprocessing` |
| Risk | Rates are MW/h in `DISPATCHLOAD`, MW/min in bids. A battery's composite rate reads observed `initial_mw` aligned to the ramp grid with `NEMUnitState(initial, 0)`; a `NaN` stamp must stay `NaN` into the kernel. The AEMO citation (SO_OP_3705 Appendix C) moves with the composite call. |

### Task 6: Observed-state inputs (the former seeds) [move]

| Item | Value |
| --- | --- |
| Old | `_set_state_seeds!` (`…/offers/effective_offers.jl:75-109`), `_fixed_load_*` helpers (moved there in Task 2), `unit_state`, `_state_initial_mw*`, `_is_unobserved_stamp`, `_unobserved_stamp_mask`, `StateSource`, `ObservedState`, `_state_source` (`…/types/state.jl`), `_FIXED_LOAD_SERIES` names in `…/formulations/fixed_loads.jl` |
| Names | `NEM_STATE_INPUT_SERIES = (initial_mw = "initial_mw_seed", fixed_load = "fixed_load_seed", fixed_load_invoked = "fixed_load_invoked_seed")` in `src/accessors/series_names.jl` |
| Reader | `observed_unit_states(device, stamps::AbstractVector{DateTime})::Vector{NEMUnitState}` in `src/system/replay_inputs/state_inputs.jl`: the rules of `unit_state(::ObservedState, …)` (unobserved stamp gives `NEMUnitState(0.0, 0)`; first registered stamp gives mode 0; a non-finite mode at an observed stamp throws the existing message), read once per device over the grid |
| Writer | `_set_observed_state_inputs!(sys)`: the three series. `initial_mw` in MW; `fixed_load` as `target / base`; `fixed_load_invoked` as `1.0` or `0.0`, through `effective_fixed_load` and `fixed_load_invoked`. No `with_units_base`. |
| AEMSim | `dispatch.jl:276`, `storage.jl:82`, `fixed_loads.jl:8-11` read `NEM_STATE_INPUT_SERIES`. Delete `StateSource`, `ObservedState`, `unit_state`, `_state_source` and their exports. `…Simulations/test/state.jl` moves to root `test/replay_inputs/state.jl`. |
| Groups | root `replay_inputs_state`, `unit_data`; Simulations `nem_dispatch`, `nem_dispatch_toy`, `energy_limits`, `replay_validation` |
| Risk | `_set_state_seeds!` ran inside `with_units_base(sys, "SYSTEM_BASE")`. Before removing the toggle, confirm by reading `_fixed_load_step_series` that nothing in it reads a PSY per-unit getter; if something does, replace it with the raw value divided by `PSY.get_base_power(sys)` and expect a `parameter/` difference of at most 1 ulp. PSI does not update parameters before step 1 (the build-time values are the series values at the build stamp), which is unchanged. |

### Task 7: FCAS kernels in scalar MW shape (R11) [move]

**Files:**

- Create: `src/derivations/fcas.jl`, `test/replay_inputs/fcas_kernels.jl` (root group `replay_inputs_fcas_kernels`)
- Modify: `src/derivations/state.jl`, `src/accessors/series_names.jl`

**Interfaces (produced), all exported from AEM, all in MW:**

- `FCAS_BAND_COUNT = 10`, `FCAS_INACTIVE_LIMIT_MW = 1.0e5`, `fcas_effective_series_name(bid_type::BidType, decremental::Bool)`, `fcas_ramping_series_name(bid_type::BidType)`, `fcas_offer_sides(direction::FCASBidDirection)`, `fcas_upper_regulation_service(device)` (moved from `…/offers/fcas_effective.jl`, same strings).
- `fcas_state_stranded_ok(trap::FCASTrapezium, state::NEMUnitState, storage::Bool)::Bool`: the `storage` keyword becomes positional.
- `fcas_preconditions_ok(trap::FCASTrapezium, total_band_width::Float64, energy_max_avail_gen::Float64, energy_max_avail_load::Float64, agc_status::Int, is_regulation::Bool, decremental::Bool, storage::Bool)::Bool`: the body of `_fcas_preconditions`, `_fcas_sign_ok` and `_fcas_energy_max_avail_ok`, with `NaN` for an absent energy availability and `-1` for an unknown AGC status.
- `fcas_effective_offer(trap::FCASTrapezium, band_widths::NTuple{10, Float64}, enabled::Bool, inactive::Float64)::NTuple{15, Float64}`: the body of `_fcas_effective_offer`.
- `fcas_ramping_limits(capability::Float64, bdu_capability::Float64, enabled::Bool, upper::Bool, fast_start::Bool, inactive::Float64, state::NEMUnitState)::NTuple{2, Float64}`: the per-interval body of `_fcas_effective_ramping`; `bdu_capability` is `0.0` for a device that is not bidding both sides.

- [ ] **Step 1: Failing tests:** port the assertions of `…Simulations/test/fcas_preprocessing.jl` and `state.jl` that exercise these rules, with MW inputs. Add: `fcas_effective_offer(trap, widths, false, 1.0e5) == (0.0, -1.0e5, 1.0e5, 0.0, 0.0, ntuple(_ -> 0.0, 10)...)`; `fcas_ramping_limits(0.0, 0.0, true, true, false, 1.0e5, NEMUnitState(50.0, 0)) == (1.0e5, 1.0e5)`.
- [ ] **Step 2:** Run the root group. Expected: FAIL (undefined).
- [ ] **Step 3:** Implement. AEMSim is not rewired in this task; update its one call of `fcas_state_stranded_ok` to the positional form.
- [ ] **Step 4:** Precompile; root `replay_inputs_fcas_kernels`, `fcas`, `fcas_scaling`; Simulations `fcas_preprocessing`. Expected: PASS. GATE(07). Runic, commit.

**Risks:** none to the gate (no wiring). Review confirms each rule keeps its *FCAS Model in NEMDE* section citation (§4.1, §5, §6.1, §6.4) and the BDU net-axis and both-sides preconditions.

### Task 8: FCAS effective offers written by AEM [move]

| Item | Value |
| --- | --- |
| Old | `…/offers/fcas_effective.jl` (whole file), the FCAS readers in `…/offers/accessors.jl` that only the writer uses (`get_scaled_fcas_trapezium`, `get_fcas_agc_ramp_capability`, `get_fcas_agc_status`, `_fcas_trapezium_window`, `_read_optional_fcas_scaling_series`; grep each before deleting), `_fcas_units_multiplier` use |
| Writer | `_set_fcas_effective_offers!(sys)` in `src/system/replay_inputs/fcas_effective.jl`: for every available contributing device of every `FCASService` (skipping `_is_unpriced_unavailable`), series `fcas_effective_series_name(bid_type, decremental)` (`NTuple{15}`) and `fcas_ramping_series_name(bid_type)` (`NTuple{2}`) on the bid trapezium's stamps. It reads raw MW series, applies `scale_fcas_trapezium` and the Task 7 kernels in MW, and divides MW outputs by `PSY.get_base_power(sys)` at the end (slope coefficients are not divided). It reads the AGC ramp series Task 5 wrote and the states from `observed_unit_states`. No `with_units_base`. |
| AEMSim | `formulations/fcas.jl` and `checks/fcas.jl` read the AEM name functions. `_fcas_bid_inputs` stays until Task 11. |
| Groups | root `replay_inputs_fcas`, `fcas`, `fcas_service`; Simulations `fcas_market`, `fcas_preprocessing`, `effective_offers`, `replay_validation` |
| Expected gate | `GATE PASS`. `parameter/FCAS*` differences up to about 1e-12 are expected (MW arithmetic then one division, instead of per-unit arithmetic); record the printed maximum in the commit body. |
| Risk | Highest in the migration. The old code compared the starting output with enablement bounds in per-unit with deliberately matched arithmetic; MW comparisons on raw values can flip an enablement flag where the old rounding decided it. If the gate fails on a variable, find the unit and interval from the worst key: if the MW comparison is the correct reading of AEMO's rule, stop and report to the user with the case (do not loosen the gate); otherwise fix the kernel. **Fallback decided here:** keep the kernels unit-agnostic and have the writer pass `x / base` values (the baseline arithmetic), and record that in ADR 0101. |

### Task 9: Tie-break scales and the `EnergyTieBreak` service [move]

| Item | Value |
| --- | --- |
| Old | `…/offers/tie_break.jl` (`tie_break_series_name`, `tie_groups`, `_tie_break_offers`, `_tie_break_active_bands`, `_tie_break_stamp_bands`, `_set_tie_break_scales!`), `tie_break_scale` (`derivation.jl`), `check_tie_break_pairs` and helpers (`…/checks/tie_break.jl`) |
| Kernel | `tie_break_scale(width::Float64, reference_width::Float64)::Float64` in `src/derivations/tie_break.jl`; `tie_groups` moves beside it |
| Writer | `_set_tie_break!(sys)` in `src/system/replay_inputs/tie_break.jl`: writes each `tie_break_series_name(band, decremental)` once and adds the `EnergyTieBreak` service once (no remove and re-add, no series removal). It then runs the moved pair check over `_replay_interval_stamps(sys)` as `_check_tie_break_prices(sys, stamps)` and throws its existing message. |
| AEMSim | `formulations/tie_break.jl` reads the AEM names; `prepare_replay!` drops its `check_tie_break_pairs` line; delete `…/checks/tie_break.jl`; update the message at `formulations/tie_break.jl:113` to name `nem_system`. |
| Kernel test | `tie_break_scale(30.0, 60.0) == 0.5`; `tie_break_scale(30.0, 0.0) == 0.0` |
| Groups | root `replay_inputs_tie_break`, `tie_break_service`; Simulations `nem_dispatch`, `replay_validation`, `pipeline` |
| Risk | G7: the scales stay a per-step `ConstraintCoefficientParameter`, untouched. The service's contributing devices and their order decide row labels and pair order in `TieBreakConstraint`; build the service from the same device iteration order as today, or the LP column order changes and HiGHS may pick another tied vertex (ADR 0094). The old check ran over `steps`; it now runs over the System's replay intervals (R5). |

### Task 10: Loss-factor demand coefficient [move]

| Item | Value |
| --- | --- |
| Old | `…/offers/loss_demand.jl` (`loss_demand_coefficient`, `set_loss_demand_coefficients!`, `_area_loss_demand` with its `with_units_base` at line 88) |
| Kernel | `loss_demand_coefficient(model::InterconnectorLossModel, demand::AbstractDict)::Float64` moved to `src/derivations/loss_demand.jl` (not state-dependent, so it keeps its shape) |
| Writer | `_set_loss_demand_coefficients!(sys)` in `src/system/replay_inputs/loss_demand.jl`: `NEM_SERIES.loss_demand_coefficient` on each loss-modelled `AreaInterchange`. Area demand is read from the raw demand series in MW, without `with_units_base`. |
| AEMSim | Update the message at `formulations/interconnector_losses.jl:176` to name `nem_system`. Drop the two exports. |
| Groups | root `replay_inputs_loss_demand`, `interconnector_losses`; Simulations `interconnector_losses` |
| Risk | `_area_loss_demand` read demand under `SYSTEM_BASE`; the coefficient formula expects MW demand. Read lines 67-101 first and keep the same unit the formula received. The series name contains no `"__"` (anatomy gotcha 15). A missing series on a device model is skipped silently by PSI (gotcha 12); `_check_loss_demand_coefficients` stays as the guard. |

---

### Task 11: Fixed series names; remove `NEMDispatchInputs` and `set_effective_offers!` (D1, R7)

**Files:**

- Modify: `…Simulations/src/formulations/dispatch.jl:28-215,269-282`, `…/formulations/storage.jl`, `…/formulations/fcas.jl` (`_fcas_band_price_batches` and the trapezium readers), `…/psi_compat.jl:112-124`, `…/checks/dispatch_envelope.jl:52-71`, `…/checks/replay_inputs.jl`, `…/checks/replay_range.jl:51`, `…/types/state.jl`, `…/offers/accessors.jl`, module exports
- Delete: `…Simulations/src/offers/effective_offers.jl`
- Test: `…Simulations/test/nem_dispatch.jl`, `replication_inputs.jl`, `effective_offers.jl` (delete what remains after Tasks 3-10, and the group if empty)

**Interfaces (produced):**

- `_ramp_series_name(direction)` returns `NEM_SERIES.ramp_up_rate` or `NEM_SERIES.ramp_down_rate`; `_availability_series_name(device, param)` (exists at `dispatch.jl:113`) is the only source of the `MAXAVAIL` name.
- FCAS bid series are read from the device's `NEMFCASBid` keys (`get_fcas_bids(_nem_offer_cost(device))`), not from an attribute.

- [ ] **Step 1: Failing test** in `nem_dispatch.jl`: `!isdefined(AEMS, :NEMDispatchInputs)`, `!isdefined(AEMS, :NEMFCASInputs)`, `!isdefined(AEMS, :set_effective_offers!)`, and after `nem_system` on the mock hive no device carries a supplemental attribute whose type is defined in `AEMS`.
- [ ] **Step 2:** Run Simulations `nem_dispatch`. Expected: FAIL.
- [ ] **Step 3:** Replace every `_inputs_series_name(…)` call with the fixed name; delete `_dispatch_inputs_attribute`, `_inputs_series_name`, `_DERIVED_INPUT_FIELDS` use in `_has_nem_dispatch_limits` (it now checks the fixed names with `PSY.has_time_series`), both `PSI._get_time_series_name` methods, `_attach_dispatch_inputs!`, `_dispatch_inputs`, `_fcas_inputs`, `_fcas_bid_inputs`, the two structs and `set_effective_offers!`.
- [ ] **Step 4:** Precompile; Simulations `nem_dispatch`, `nem_dispatch_toy`, `storage_availability`, `energy_limits`, `fcas_market`, `replication_inputs`, `replay_workflow`. Expected: PASS. GATE(11). Runic, CHANGELOG, commit.

**Risks:** deleting the storage `_get_time_series_name` methods makes `ActivePowerOut/InTimeSeriesParameter` fall back to `get_default_time_series_names` (`storage.jl:36-46`), which already names the two `MAXAVAIL` series; confirm the names are equal for every battery in the real run (the old method read the key's name per device). `add_parameters!` takes one name for all devices of a type from `first(devices)`: a `ControllableLoad` type mixing `LOAD` bidders and a GEN-bidding demand response unit behaves as today (unchanged, noted for the ADR).

### Task 12: Forecast transform and range rules in AEM (D1, C4, R5)

**Files:**

- Create: `src/system/replay_inputs/forecasts.jl`, `test/replay_inputs/range.jl` (root group `replay_inputs_range`)
- Modify: `src/system/replay_inputs.jl`, `src/system/nemde.jl:62-66`, `src/AustralianElectricityMarkets.jl` (export `replay_intervals`), `…Simulations/src/checks/replay_range.jl`, module includes and exports
- Delete: `…Simulations/src/checks/replication_steps.jl`, `…Simulations/src/checks/financial_year.jl`

**Interfaces (produced):**

- `_set_replay_forecasts!(sys) -> Nothing`: `PSY.transform_single_time_series!(sys, Minute(5), Minute(5))`, the last call in `_set_replay_inputs!`.
- `replay_intervals(sys::PSY.System) -> Vector{DateTime}`: `PSY.get_forecast_initial_times(sys)[1:(end - 1)]`; throws `ArgumentError` when `sys` has no forecasts.
- `_check_replay_range(date_range) -> Nothing`, called first in `nem_system(…, ::NEMDEConfiguration)`: requires step 5 minutes and `length(date_range) >= 3`; with `r = date_range[1:(end - 2)]`, requires one trading day (`Date(first(r) - Hour(4) - Minute(5)) == Date(last(r) - Hour(4) - Minute(5))`) and one financial year (`_financial_year_start(first(r)) == _financial_year_start(last(r))`).
- AEM keeps `never_invoked` logic for Task 13; `never_invoked_constraints` moves there. Until then `prepare_replay!` keeps calling its own copy (move the function into `replay_range.jl`).

- [ ] **Step 1: Failing tests** (`range.jl`), on the mock replay hive unless noted:

```julia
ok = t:Minute(5):(t + Minute(20))
sys = nem_system(db, NEMDEConfiguration(); date_range = ok)
@test PSY.get_time_series_counts(sys).forecast_count > 0
@test replay_intervals(sys) == collect(t:Minute(5):(t + Minute(10)))
@test_throws ArgumentError nem_system(db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(5)))
# pure rule, no cache needed
check = AustralianElectricityMarkets._check_replay_range
day(a, b) = a:Minute(5):(b + Minute(10))
@test check(day(DateTime(2026, 6, 4, 4, 5), DateTime(2026, 6, 5, 4, 0))) === nothing      # trailing stamps cross 04:00
@test_throws ArgumentError check(day(DateTime(2026, 6, 4, 4, 0), DateTime(2026, 6, 4, 4, 5)))   # crosses trading day
@test check(day(DateTime(2026, 6, 30, 4, 5), DateTime(2026, 7, 1, 0, 0))) === nothing
@test_throws ArgumentError check(day(DateTime(2026, 6, 30, 23, 55), DateTime(2026, 7, 1, 0, 5))) # crosses financial year
```

and a file-backed case: `nem_system(…; date_range = ok, time_series_in_memory = false, time_series_directory = mktempdir())` has forecasts too.

- [ ] **Step 2:** Run the root group. Expected: FAIL.
- [ ] **Step 3:** Implement. In AEMSim delete `_prepare_replay_forecasts!`, `check_replication_steps`, `check_single_financial_year` and their calls and exports.
- [ ] **Step 4:** Fix callers: `grep -rn 'date_range' AustralianElectricityMarketsSimulations/test test docs/literate` for two-stamp ranges or ranges crossing 04:00 or 1 July and extend or move them; `prepared_test_system` (`…/test/replay_workflow.jl:66`) becomes plain `nem_system`; tests of `check_single_financial_year` and `check_replication_steps` are replaced by `range.jl`.
- [ ] **Step 5:** Precompile; root `replay_inputs_range`, `replay_network`, `system_build_coverage`, `timeseries_setters`; Simulations `time_basis`, `pipeline`, `replay_workflow`, `replication_inputs`, `stock_simulation`. Expected: PASS. GATE(12). Runic, CHANGELOG, commit.

**Risks:** hand-built fixtures now hold forecasts as soon as `_set_replay_inputs!` returns, so any later `add_time_series!` in a test fails; such edits move before the call. PSI's own `auto_transform_time_series!` (fork `operation/decision_model.jl:68`) must stay a no-op; Task 19 makes the constructor reject non-default `horizon` and `interval`. `PSY.to_json` after a transform is covered by `system_build_coverage` (acceptance 7); if the round-trip fails here, do not fix it in this task: record it for Task 22.

### Task 13: Constraint data facts decided by AEM (C2, C5)

**Files:**

- Create: `src/system/replay_inputs/constraints.jl`, `test/replay_inputs/constraints.jl` (root group `replay_inputs_constraints`)
- Modify: `src/types/build_report.jl`, `src/accessors/constraints.jl`, `src/system/replay_inputs.jl`, `src/AustralianElectricityMarkets.jl`

**Interfaces (produced):**

- `NEMBuildReport` gains `unavailable_constraints::Vector{Dict{String, Any}}` (rows `"constraint"`, `"reason"`), default empty, included in `==`, `hash` and the stored form.
- `get_unavailable_constraints(sys) -> DataFrame` (columns `constraint::String`, `reason::Symbol`), exported.
- `_set_constraint_availability!(sys) -> Nothing`: for each `GenericConstraint`, `reason = :never_invoked` when its `invoked` series is zero at every stamp of `_replay_interval_stamps(sys)`, else `:no_available_device` when it has contributing devices and none is available; sets `available = false` for those and records them. Runs after the tie-break writer and before prices.

- [ ] **Step 1: Failing tests:** a System whose range holds a constraint invoked only at the last data stamp (outside the replay intervals) reports it `:never_invoked` and unavailable; a constraint whose only contributing device is unavailable reports `:no_available_device`; a constraint that is both reports `:never_invoked`; an ordinary constraint stays available; the report survives `set_build_report!`/`get_build_report`.
- [ ] **Step 2:** Run the root group. Expected: FAIL.
- [ ] **Step 3:** Implement. AEMSim is unchanged: `prepare_replay!` still computes the same sets and its `set_available!(false)` calls now hit constraints that are already unavailable.
- [ ] **Step 4:** Precompile; root `replay_inputs_constraints`, `constraints`, `pscb_constraints`, `system_build_coverage`; Simulations `nem_constraints`, `replay_workflow`. GATE(13) and additionally `diff $B/real_1h/skipped_constraints.csv $C/real_1h/skipped_constraints.csv`.
- [ ] **Step 5:** Runic, CHANGELOG, commit.

**Risks:** `exclude_unmodeled_services!` iterates only available constraints, so rows AEM already disabled would vanish from its return value; the `skipped_constraints.csv` diff must be empty, which requires `prepare_replay!` to merge `get_unavailable_constraints(sys)` into its returned rows in this task (reason, `n_missing = 0`), replacing `never_invoked_constraints` (delete it). Device availability must be final before this writer runs.

### Task 14: Checks in `validate_template`; remove `exclude_unmodeled_services!` and `prepare_replay!` (G1, G3, D2)

**Files:**

- Modify: `…Simulations/src/checks/nem_constraints.jl`, `…/checks/template.jl`, `…/checks/dispatch_envelope.jl`, `…/templates/template_nemde.jl`, `…/problems/nem_dispatch.jl:58-71`, `…/precompile.jl`, module exports, `scripts/replay_batch_worker.jl:44-61`, `…Simulations/test/real_data/runtests.jl:38-62`, `…/test/real_data/benchmark_updates.jl`, `…/test/template_helpers.jl` (`replay_template`), `test/scripts/replay_workflow.jl`, `docs/literate/tutorials/nemde_aem.jl`, `scripts/README.md`
- Delete: `…Simulations/src/checks/replay_range.jl`

**Interfaces (produced):**

- `template_nemde(; exclude_constraints = Dict{String, Symbol}())` as decided above.
- `replay_skipped_constraints(sys::PSY.System, template::PSI.ProblemTemplate) -> DataFrame`, exported, pure: rows from `get_unavailable_constraints(sys)` (`n_missing = 0`), from the template's `"excluded_constraints"` attribute for names that are available constraints of `sys` (`n_missing = 0`), and one row per remaining available constraint the template cannot build (`reason`, `n_missing` from `_constraint_diagnosis`); sorted by `constraint`. A template with no `GenericConstraint` model returns the data-fact rows only. Works on a caller's aggregated template and on a model's expanded copy.
- `_blocked_constraints(sys, template) -> Vector{@NamedTuple{constraint::String, reason::Symbol}}`: diagnoses that are not tolerated (`_left_out_reasons`, `_left_out_types` unchanged).
- `PSI.validate_template(model::PSI.DecisionModel{NEMDispatchProblem})` order: cap and slack cost (unchanged); require `PSY.get_time_series_counts(sys).forecast_count > 0`, else `ArgumentError("…build sys with nem_system(db, NEMDEConfiguration(); date_range)")`; unknown names in `"excluded_constraints"` throw `ArgumentError`; `check_template_against_sys`; `check_fcas_services`; throw on `_blocked_constraints`; delete from `PSI.get_service_models(template)` every per-name `GenericConstraint` model whose name has a template-fact row; `check_dispatch_envelope(template, sys)` over `replay_intervals(sys)`; `PSI.validate_template_impl!(model)`.
- `check_dispatch_envelope(template, sys)` (two arguments); the four-argument method is deleted. `_check_energy_limit_series` in `construct_device!` keeps its window arguments.

- [ ] **Step 1: Failing tests** in `…Simulations/test/nem_constraints.jl` and `replay_workflow.jl`:
  - `!isdefined(AEMS, :prepare_replay!)`, `!isdefined(AEMS, :exclude_unmodeled_services!)`.
  - Full template on the mock replay System: `replay_skipped_constraints(sys, template_nemde())` equals the frame `prepare_replay!` returned at the previous commit (hard-code the rows from `$C/mock/skipped_constraints.csv` of GATE(13)).
  - `template_nemde(; exclude_constraints = Dict(name => :manual))`: the row `(name, :manual, 0)` is reported, the built model has no container with meta `name`, and `PSY.get_available(gc)` is still `true`.
  - `exclude_constraints = Dict("NOPE" => :manual)`: `PSI.validate_template(model)` throws `ArgumentError`.
  - Reduced template (`energy_template()` plus `with_generic_constraints!`, no FCAS model): constraints with FCAS terms are reported `:unmodeled_fcas_service`, the simulation builds (`BUILT`) and executes, and `read_constraint_violations(results, sys)` and `read_solved_interval(results, sys)` return without error.
  - Building a second `DecisionModel` and `Simulation` on the same System succeeds and `PSY.get_time_series_counts(sys)` is unchanged; `replay_skipped_constraints` called twice returns equal frames.
- [ ] **Step 2:** Run Simulations `nem_constraints`, `replay_workflow`. Expected: FAIL.
- [ ] **Step 3:** Implement the predicate, pruning and `validate_template`; delete `exclude_unmodeled_services!`, `_exclude_unmodeled_services!`, `_set_replay_availability!`, `_REPLAY_EXCLUSIONS_KEY`, `prepare_replay!`.
- [ ] **Step 4:** Audit units (R9): `grep -nE 'with_units_base|get_active_power|get_max_active_power|get_rating|get_reactive|get_base_power' AustralianElectricityMarketsSimulations/src/checks`. Expected: no output; rewrite any hit to read `NEMUnitData` or raw series values.
- [ ] **Step 5:** Result readers: `grep -rn 'get_available, GenericConstraint\|get_components(GenericConstraint' AustralianElectricityMarketsSimulations/src/results AustralianElectricityMarketsSimulations/src/formulations`. Any loop that assumes every available constraint has containers must select by container key (`PSI.has_container_key`) instead.
- [ ] **Step 6:** Update the worker: delete the `prepare_replay!` line; after the `DecisionModel` is constructed set `skipped = replay_skipped_constraints(sys, template)`; `t1 = time()` moves to just before the `DecisionModel` call. Column names, file names and `insertcols(skipped, 1, :chunk => …)` are unchanged. Update `precompile.jl`, `replay_real`, `benchmark_updates.jl`, `replay_template`, `run_replay`/`replay_simulation` in `test/scripts/replay_workflow.jl` and the tutorial to the G3 sequence.
- [ ] **Step 7:** Precompile; Simulations `nem_constraints`, `nem_dispatch`, `nem_dispatch_toy`, `fcas_market`, `pipeline`, `replay_workflow`, `replay_scripts`, `stock_simulation`, `replication_inputs`. Expected: PASS.
- [ ] **Step 8:** **CHECKPOINT(cp1).** Also `diff` the batch `skipped_constraints.csv` against the baseline batch. Runic, CHANGELOG, commit.

**Risks:** `build!` swallows exceptions and returns `FAILED` (gotcha 1), so tests of throwing checks call `PSI.validate_template(model)` directly. The aggregated model is expanded at `DecisionModel` construction (`finalize_template!`), and the expansion passes `attributes` but drops `time_series_names` and feedforwards (R8): nothing may read them. PSI deletes device models with no available devices (gotcha 13) after our checks, as today. `validate_template` now runs range checks over up to 288 intervals at every build; its cost is part of the 20 s budget (measure in the checkpoint's `warm_model_build_s`). The model deep-copies the template (gotcha 2), so pruning never touches the caller's template, and the report must be computed from `sys` and the caller's template, not from the model.

---

### Task 15: Invocation mask on generic constraints (R1) [AEMO]

**Files:**

- Modify: `…Simulations/src/types/constraint_formulations.jl`, `…/formulations/generic_constraints.jl:1-8,455-530`, `…/formulations/slacks.jl`, `…/psi_compat.jl`, `…/results/violations.jl`, module exports
- Test: `…Simulations/test/nem_constraints.jl`

**Interfaces (produced):**

- `struct GenericConstraintInvocationMaskParameter <: PSI.ConstraintCoefficientParameter end`; default series `NEM_CONSTRAINT_SERIES.invoked`; `PSI.get_multiplier_value` is `1.0`; `PSI._unwrap_for_param(::GenericConstraintInvocationMaskParameter, v::Float64, _) = 1.0 - v`.
- `struct GenericConstraintRelaxation <: PSI.VariableType end`: container `(GenericConstraint, [name], ["up", "down"], time_steps; meta = name)`, both non-negative, no objective term.
- `GenericConstraintSlackCostParameter` is deleted.
- Row: `lhs (+ slack terms as today) + r⁺ − r⁻ (sense) rhs`, built with placeholder coefficients `+1.0` and `−1.0`, then `PSI.add_coefficient_target!(container, PSI.ParameterKey(GenericConstraintInvocationMaskParameter, GenericConstraint, name), name, t, row, r_up, 1.0)` and `(…, r_down, -1.0)`.
- Objective: `PSI.add_to_objective_invariant_expression!(container, scale * slack[name, t])` with `scale = base_power * interval_cost_coefficient(constraint_cvp_factor(gc), resolution) * mpc`, the same product as today without the `invoked` factor.

- [ ] **Step 1: AEMO check (nem-expert):** confirm and record (a) a generic constraint not invoked in a dispatch interval is absent from that interval's NEMDE run, (b) the violation penalty of an invoked constraint is its CVP factor times the Market Price Cap (Schedule of Constraint Violation Penalty factors), (c) the relaxation is unpriced and is a modelling device with no NEMDE counterpart (a departure to record in ADR 0101).
- [ ] **Step 2: Failing tests**, on a System with one constraint invoked at interval 1 and not at interval 2 and a right-hand side that cannot be met:
  - interval 1: slack `> 0`, objective includes `scale * slack` (compare with the value computed in the test from `constraint_cvp_factor`, the cap and the base);
  - interval 2 (after one `_update_step_parameters!` or a two-step simulation): both slacks `== 0.0`, `r⁺ + r⁻ > 0`, the row's dual `== 0.0`;
  - `JuMP.normalized_coefficient(row, r_up)` is `0.0` at interval 1 and `1.0` at interval 2;
  - no parameter key of type `GenericConstraintSlackCostParameter` exists, and `PSI.has_variant_contributors`-style state is not asserted here (Task 18 asserts it).
- [ ] **Step 3:** Run Simulations `nem_constraints`. Expected: FAIL.
- [ ] **Step 4:** Implement. `read_constraint_violations` reports slack values only (never the relaxation).
- [ ] **Step 5:** Precompile; Simulations `nem_constraints`, `replay_validation`, `replay_workflow`, `pipeline`, `recurrent_objective_cache`. Expected: PASS.
- [ ] **Step 6:** GATE(15) with `GATE_FLAGS="--mask-gc-slacks --allow-new GenericConstraintRelaxation"` (from now on). Compare `$C/real_1h/comparison_summary.csv` with the baseline's: every metric equal to 1e-9. Runic, CHANGELOG, commit with the citations.

**Risks:** this changes the LP (new columns, constant slack costs), so HiGHS may reach another vertex among ties; the 1e-9 gate on all non-slack variables decides. Slack values at non-invoked intervals legitimately change (they were free and are now zero), which is why the mask flag exists; duals at non-invoked intervals must stay zero and are gated unmasked. Service-owned coefficient parameters need the key meta to be the service name (the fork's update method looks the service up by `key.meta`, `parameters/coefficient_parameters.jl:127`). The fork's `add_coefficient_target!` rejects `rebuild_model = true`. If `_unwrap_for_param` is not applied to scalar service series in the fork's service `add_parameters!` path, fall back to an AEM-written series `NEM_CONSTRAINT_SERIES.relaxation = "constraint_relaxation"` (`1.0 .- invoked`, written in `_add_nem_constraints!`) and note it in the ADR.
If the gate fails on non-slack variables and the cause is a tied vertex, stop and report to the user; do not switch to a big-M right-hand side (rejected in D6).

### Task 16: Energy band prices as typed day-constants (D6, R6) [AEMO]

**Files:**

- Create: `src/system/replay_inputs/prices.jl`, `test/replay_inputs/prices.jl` (root group `replay_inputs_prices`)
- Modify: `src/types/nem_offer_cost.jl:57-100` (`NEMEnergyBid.band_prices`, constructor keyword default `nothing`, `==`, `hash`, deserialisation), `src/system/replay_inputs.jl`, `…Simulations/src/types/energy_offers.jl`, `…/formulations/energy_offers.jl:130-207`, `…/psi_compat.jl:99-108`, module exports
- Test: `test/types/nem_offer_cost.jl`, `…Simulations/test/energy_offer_violations.jl`, `nem_dispatch.jl`

**Interfaces (produced):**

- `_day_band_prices(curves::Vector{PiecewiseStepData}, stamps_in_replay::AbstractVector{Bool}, label::AbstractString)::NTuple{10, Float64}`: the y-coordinates at the first replay interval padded with `0.0`; throws `ArgumentError("band prices of $label vary within the replay range; a NEMDE system covers one trading day")` when any other replay interval differs; throws for more than 10 bands.
- `_set_band_prices!(sys) -> Nothing` (energy part): for each energy bid, `band_prices = _day_band_prices(<energy_offer series values>, …, "<DUID> ENERGY <side>")` (already referred and rounded by Task 3), stored by replacing the bid through `_set_energy_bid!`. Deletes `_check_tie_break_prices` (subsumed).
- AEMSim: `EnergyBandPriceParameter` and its `_unwrap_for_param` are deleted; the cost term is `PSI.add_to_objective_invariant_expression!(container, (scale * price[b]) * bands[name, label, t])` with `scale` exactly as at `energy_offers.jl:188-190`.

- [ ] **Step 1: AEMO check (nem-expert):** find and record the NER clauses and AEMO procedure text establishing that energy price bands are fixed for the trading day and that rebids change quantities only (candidates to verify, not to assume: NER 3.8.6 and 3.8.22). Record the same for MNSP (3.8.6A) and FCAS (3.8.7A) now, for Tasks 17 and 18.
- [ ] **Step 2: Failing tests:** root: a mock System's bids carry `band_prices` equal to `referred_price` of the raw bands; a hand-built System whose `energy_offer` curve changes price at the second replay interval makes `_set_replay_inputs!` throw; a price change only at the trailing two stamps does not throw; `NEMEnergyBid` round-trips `band_prices` through its serialised form. Simulations: no parameter key of type `EnergyBandPriceParameter`; the objective coefficient of band variable `b` equals `scale * band_prices[b]`.
- [ ] **Step 3:** Run root `replay_inputs_prices`, Simulations `energy_offer_violations`. Expected: FAIL.
- [ ] **Step 4:** Implement.
- [ ] **Step 5:** Precompile; root `replay_inputs_prices`, `nem_offer_cost`, `market_bids`, `system_build_coverage`, `tie_break_service`; Simulations `nem_dispatch`, `energy_offer_violations`, `recurrent_objective_cache`, `replay_workflow`. GATE(16). Runic, CHANGELOG, commit with the citations.

**Risks:** the old coefficient was `scale * value * multiplier` with multiplier `1.0` (`fork parameters/cost_parameters.jl`, `_add_cost_target_term!`); `scale * price` is bit-identical. Moving terms from the variant to the invariant expression must not change the model, only who owns the term. Band labels are positional: this is safe for energy because `_curves_on_grid` keeps empty bands. `recurrent_objective_cache` tests the fork's variant path and may need rewriting or deleting once no variant term remains (decide in Task 18).

### Task 17: FCAS band prices as typed day-constants [AEMO]

**Files:** `src/types/nem_offer_cost.jl:108-130` (`NEMFCASBid.band_prices`), `src/system/replay_inputs/prices.jl`, `test/replay_inputs/prices.jl`, `…Simulations/src/formulations/fcas.jl:700-778`, `…/types/` (delete `FCASBandPriceParameter`), `…/psi_compat.jl:73-79`, `…Simulations/test/fcas_market.jl`

**Interfaces (produced):** `_set_band_prices!` also fills each FCAS bid from its `offer_curves` series with `_day_band_prices` (no referral, no rounding). `_add_fcas_band_costs!` adds `PSI.add_to_objective_invariant_expression!(container, (scale * price[b]) * bands[dname, label, t])` with `scale = base_power * interval_hours(resolution)`; `_fcas_band_price_batches` and its `add_parameters!` calls are deleted.

- [ ] **Step 1:** Record the FCAS citation from Task 16 Step 1 for this commit.
- [ ] **Step 2: Failing tests:** root: `band_prices` equals the first replay interval's FCAS prices; an FCAS curve whose price changes inside the replay range throws naming the DUID and service. Simulations: no `FCASBandPriceParameter` key; coefficient of an FCAS band variable equals `scale * band_prices[b]`.
- [ ] **Step 3:** Run, expect FAIL; implement; precompile; root `replay_inputs_prices`, `nem_offer_cost`, `fcas`; Simulations `fcas_market`, `fcas_preprocessing`, `replay_workflow`. GATE(17). Runic, CHANGELOG, commit.

**Risks:** each `(device, side)` reads its own bid, so the old batching by series name disappears; a device bidding one service on both sides has two bids and two price tuples. FCAS band widths still come from the `fcas_effective` series (unchanged).

### Task 18: MNSP band prices as typed day-constants; no cost parameters left [AEMO]

**Files:** `src/types/network_data.jl:126-142` (`NEMMNSPBid.band_prices`), `src/system/mnsp.jl:185-191` (`_mnsp_offer_curve` keeps all 10 bands), `src/system/replay_inputs/prices.jl`, `test/replay_inputs/prices.jl`, `test/mnsp_offers.jl`, `test/types/network_data.jl`, `…Simulations/src/formulations/mnsp.jl:385-410`, `…/types/mnsp.jl` (delete `MNSPBandPriceParameter`), `…/psi_compat.jl:81-87`, `…Simulations/test/mnsp_limits.jl`, `recurrent_objective_cache.jl`

**Interfaces (produced):** `_mnsp_offer_curve(row)` returns `PiecewiseStepData([0.0; cumsum(avail)], prices)` over all 10 bands, so band `k` is always `PRICEBAND<k>`. `_set_band_prices!` fills each `NEMMNSPBid` with `_day_band_prices`. `_add_mnsp_band_costs!` uses the invariant expression with `scale = base_power * interval_hours(resolution)`.

- [ ] **Step 1:** Read Task 0 Step 10's MNSP finding and record the MNSP citation from Task 16 Step 1.
- [ ] **Step 2: Failing tests:** root: an MNSP row with bands 1 and 3 available yields a curve with 10 segments and widths `[w1, 0, w3, 0, …]`; `band_prices` equals `PRICEBAND1..10`. Simulations: no `MNSPBandPriceParameter` key. Shell step: `grep -rnE 'TimeSeriesCostParameter|add_cost_target!|_apply_cost_targets!' AustralianElectricityMarketsSimulations/src`. Expected after implementation: no output. Model test: after `build!`, `!PSI.has_variant_contributors(container)` if the fork exports that query on the container; otherwise assert that no parameter in the container is a `PSI.TimeSeriesCostParameter`.
- [ ] **Step 3:** Run, expect FAIL; implement; decide `recurrent_objective_cache.jl`: delete the group if every assertion concerns variant cost terms, else keep the remaining assertions.
- [ ] **Step 4:** Precompile; root `replay_inputs_prices`, `mnsp`, `network_data`; Simulations `mnsp_limits`, `interconnector_losses`, `replay_workflow`. Expected: PASS.
- [ ] **Step 5:** **CHECKPOINT(cp2).** Record `key_type_count` (mock and real) and the per-interval `parameter_update` percentiles against the baseline. Runic, CHANGELOG, commit.

**Risks:** keeping empty MNSP bands changes the MNSP band axis (more, zero-width band variables), so the LP differs structurally though not mathematically; zero-width bands are bounded at zero and presolved away, but a tied vertex could move. If the gate fails only on MNSP band variables that are new or zero-width, pass them with `--allow-new`; if a flow or price moves, stop and report. `MNSPBandWidthParameter`'s `_unwrap_for_param` already pads to the axis. With no variant terms left, PSI stops re-setting the objective every step (gotcha 16); the step-time percentiles should improve.

---

### Task 19: Problem types, closed-loop guard, constructor rules and state accessors (G5, D5, C6, R10)

**Files:**

- Modify: `…Simulations/src/problems/nem_dispatch.jl`, `…/formulations/dispatch.jl:425-450`, `…/formulations/storage.jl`, `…/formulations/mnsp_limits.jl`, `…/formulations/mnsp.jl`, `…/formulations/penalty_costs.jl`, module exports
- Test: `…Simulations/test/nem_dispatch.jl`, `pipeline.jl`

**Interfaces (produced):**

- `abstract type AbstractNEMDispatchProblem <: PSI.DefaultDecisionProblem end`; `struct NEMDispatchProblem <: AbstractNEMDispatchProblem end`; `struct NEMClosedLoopDispatchProblem <: AbstractNEMDispatchProblem end`; all exported.
- `PSI.DecisionModel{M}(template, sys, jump_model = nothing; name = "dispatch", market_price_cap = nothing, kwargs...) where {M <: AbstractNEMDispatchProblem}`: throws `ArgumentError` when `kwargs` holds `:ext`, `:horizon`, `:interval` or `:resolution`; passes `DISPATCH_INTERVAL` for all three to `PSI.Settings`; writes `ext["closed_loop"] = M === NEMClosedLoopDispatchProblem`.
- `PSI.validate_template(::PSI.DecisionModel{NEMClosedLoopDispatchProblem})` throws `ArgumentError("closed-loop replay is not implemented")`.
- `_closed_loop(container::PSI.OptimizationContainer)::Bool = get(PSI.get_ext(PSI.get_settings(container)), "closed_loop", false)::Bool`, read once per `construct_device!` call and passed down.
- `_initial_mw_expression(container, ::Type{T}, name::String, t::Int, closed_loop::Bool)::JuMP.AffExpr` and `_mnsp_initial_flow_expression(container, name::String, t::Int, closed_loop::Bool)::JuMP.AffExpr`: `closed_loop == false` returns `parameter_ref * multiplier` as an `AffExpr` (the value `_ts_parameter_accessor` returns today); `true` throws `ArgumentError("closed-loop replay is not implemented")`.

- [ ] **Step 1: Failing tests:**

```julia
@test NEMClosedLoopDispatchProblem <: AEMS.AbstractNEMDispatchProblem <: PSI.DefaultDecisionProblem
m = PSI.DecisionModel(NEMClosedLoopDispatchProblem, template_nemde(), sys; optimizer = nemde_optimizer(), initial_time = t)
err = _caught(() -> PSI.validate_template(m))
@test err isa ArgumentError && occursin("closed-loop replay is not implemented", err.msg)
@test PSI.build!(m; output_dir = mktempdir()) == PSI.ModelBuildStatus.FAILED
@test PSI.get_ext(PSI.get_settings(m))["closed_loop"] === true
o = PSI.DecisionModel(NEMDispatchProblem, template_nemde(), sys; optimizer = nemde_optimizer(), initial_time = t)
@test PSI.get_ext(PSI.get_settings(o))["closed_loop"] === false
for kw in (:horizon, :interval, :resolution)
    @test_throws ArgumentError PSI.DecisionModel(NEMDispatchProblem, template_nemde(), sys; kw => Minute(5))
end
@test isempty(PSI.get_initial_conditions(PSI.get_optimization_container(built_observed_model)))
```

- [ ] **Step 2:** Run Simulations `nem_dispatch`. Expected: FAIL.
- [ ] **Step 3:** Implement. Route every read of `InitialPowerTimeSeriesParameter` (`dispatch.jl:439-446`, and any other `grep -rn InitialPowerTimeSeriesParameter` hit in `formulations/`) and of the MNSP `"initial_flow"` operating input through the two accessors. Formulation types gain no mode parameter.
- [ ] **Step 4:** Fix test callers that passed `horizon`, `interval` or `resolution`.
- [ ] **Step 5:** Precompile; Simulations `nem_dispatch`, `nem_dispatch_toy`, `mnsp_limits`, `storage_availability`, `pipeline`, `replay_workflow`. GATE(19). Runic, CHANGELOG, commit.

**Risks:** the accessor must produce the same expression terms in the same order as today, or constraint rows are assembled differently (same LP, possibly different row scaling order); the gate decides. Review confirms no bound, cost or constraint changed (no AEMO check needed beyond that confirmation). Generic `PSI.DecisionModel` test helpers (`_decision_model`) carry no `"closed_loop"` entry, hence the `get(…, false)` default. PSI's `DecisionModel(::Type{M}, template, sys; kwargs...)` forwards to our `DecisionModel{M}` method; check the forwarding signature in the fork (`operation/decision_model.jl:60-90`) so the keyword rejection is reached.

### Task 20: Remaining removals (D7)

**Files:** `…Simulations/src/psi_compat.jl`, `…/offers/accessors.jl`, `…/offers/derivation.jl`, `…/offers/initial_state.jl`, `…/types/state.jl`, module file, `…Simulations/test/psi_compat.jl`, `bid_store_equivalence.jl`, `tie_break_validation.jl`

- [ ] **Step 1:** For every function, constant, type and export in the listed source files, run `grep -rn '<name>' AustralianElectricityMarketsSimulations/src scripts` and delete it when its only hits are its definition, its docstring and its export. Delete files that end up empty and their `include` lines; delete the `using AustralianElectricityMarkets:` names no longer referenced (`single_series`, `remove_single_series!`, `replace_single_series!` among them).
- [ ] **Step 2:** `psi_compat.jl` keeps only: `_NEM_SERVICE_MODELS`, `PSI._modify_device_model!`, `PSI.get_initial_conditions_service_model`, and the `_unwrap_for_param` methods of parameters that still exist (`FCASOfferLimitParameter`, `FCASUpperSlopeParameter`, `FCASLowerSlopeParameter`, `FCASBandWidthParameter`, `FCASRampingLimitParameter`, `MNSPBandWidthParameter`, `EnergyBandWidthParameter`, `GenericConstraintInvocationMaskParameter`).
- [ ] **Step 3:** Delete tests of deleted names; delete a test file and its `TEST_GROUPS` entry when nothing remains.
- [ ] **Step 4:** Precompile; run the full Simulations suite once (cross-cutting deletion): `julia --heap-size-hint=4G --project=AustralianElectricityMarketsSimulations -e 'using Pkg; Pkg.test()'`. Expected: PASS. GATE(20). Runic, CHANGELOG, commit.

**Risks:** a name used only by `scripts/` or `docs/literate/` is still used; grep those too. `test/package_boundaries.jl` may assert the export lists.

### Task 21: ADR 0101, CHANGELOG, AGENTS.md and READMEs

**Files:** create `docs/adr/0101-aem-writes-aemsim-reads.md`; modify `CHANGELOG.md`, `AGENTS.md` ("Where things live", package table, Gotchas, quick start), `scripts/README.md`, `README.md` if it shows `prepare_replay!`, and append a "Superseded by 0101" line to ADR 0095, 0096 and 0098.

- [ ] **Step 1:** Write ADR 0101 with: the ownership rule (D1) and the stage order; the replay-interval definition and the one-trading-day, one-financial-year rule (C4); D2's three kinds of exclusion and the predicate; prices as typed day-constants with the NER and AEMO citations from Tasks 16-18 (G6); the invocation mask with its citations and its departure from NEMDE (the unpriced relaxation); G7's four coefficient parameters; the problem-type switch and the C6 accessors; kernel units, including the Task 8 outcome (MW kernels or the fallback); the departures from ADR 0095 (`:59`, derived inputs written by AEMSim), 0096 (custom per-step updates) and 0098 (AEMSim-precomputed series); the measured numbers (filled in Task 22).
- [ ] **Step 2:** `CHANGELOG.md` `[Unreleased]`: one consolidated entry set (Added, Changed, Removed) replacing the per-task lines.
- [ ] **Step 3:** `pre-commit run -a`. Expected: Runic, markdownlint and yamlfmt pass. Commit.

### Task 22: Milestone-1 acceptance

Run in order, one Julia process at a time; paste each result into ADR 0101's verification table and into the final checkpoint README.

- [ ] **A1 Baseline match:** CHECKPOINT(final) GATE and `real_day` compare. Expected: `GATE PASS` on `mock`, `real_1h`, `real_day`.
- [ ] **A2 NEMDE comparison:** the checkpoint's `simulation_statistics/errors.csv` against the baseline's. Report the full p5, p25, p50, p75, p90, p95, p99 and max table for both; no cell worse.
- [ ] **A3 Times:** from `$C/real_day/metrics.toml`: `warm_system_build_s + warm_model_build_s <= 20`. Report both terms and the baseline's (`warm_system_build_s + warm_prepare_s + warm_model_build_s`). Per-interval `parameter_update` and `solve_and_write` percentiles from `timing_percentiles.csv` no worse than baseline. If the 20 s budget fails: first lever, stop writing the `energy_offer` series and read widths from the raw bid series; then profile the stage per writer. Report to the user before changing scope.
- [ ] **A4 No writes, no custom updates:**

```bash
grep -rnE 'PSY\.(set|add|remove|clear|transform|copy)_[A-Za-z_]*!|IS\.(set|add|remove|clear)_[A-Za-z_]*!|\b(add_time_series!|remove_time_series!|add_component!|add_components!|remove_component!|add_service!|add_supplemental_attribute!|remove_supplemental_attribute!|replace_single_series!|remove_single_series!|transform_single_time_series!|set_available!|set_units_base_system!|with_units_base|set_build_report!|_set_replay_inputs!)\(|\b(set|add|attach|remove|replace)_[a-z_]+!\((sys|system)\b|get_ext\((sys|system)\)|\.ext\[' AustralianElectricityMarketsSimulations/src
grep -rnE 'function PSI\.(update_container_parameter_values!|update_parameter_values!|_update_parameter_values!)|^PSI\.(update_container_parameter_values!|update_parameter_values!|_update_parameter_values!)\(' AustralianElectricityMarketsSimulations/src
grep -rnE 'TimeSeriesCostParameter|add_cost_target!|_apply_cost_targets!' AustralianElectricityMarketsSimulations/src
```

  Expected: no output from any of the three (reword any docstring or message that matches). The Task 2 `methods` test passes.

- [ ] **A5 Closed-loop guard:** Task 19's test passes; quote the message.
- [ ] **A6 Key types:** `key_type_count` from `$C/mock/metrics.toml` and `$C/real_day/metrics.toml`, beside 125 and 129. Expected about 115.
- [ ] **A7 Serialisation:** root group `system_build_coverage` (JSON and HDF5 round-trip of a `NEMDEConfiguration` System, now with forecasts, the tie-break service, `band_prices` and the build report). If a part cannot round-trip, document the System as in-memory only in ADR 0101 and in the `nem_system` docstring, with the failing part named.
- [ ] **A8 Suites and records:**

```bash
julia --heap-size-hint=4G --project -e 'using Pkg; Pkg.test()'
julia --heap-size-hint=4G --project=AustralianElectricityMarketsCache -e 'using Pkg; Pkg.test()'
julia --heap-size-hint=4G --project=AustralianElectricityMarketsData -e 'using Pkg; Pkg.test()'
julia --heap-size-hint=4G --project=AustralianElectricityMarketsSimulations -e 'using Pkg; Pkg.test()'
julia --heap-size-hint=4G --project=AustralianElectricityMarketsSimulations/test AustralianElectricityMarketsSimulations/test/real_data/runtests.jl
julia --heap-size-hint=4G --project=docs docs/make.jl
pre-commit run -a
```

  Expected: all pass. ADR 0101 and `CHANGELOG.md` are complete.

- [ ] **A9 Whole-branch review** by an Opus subagent with `nem-expert` loaded, against the spec's goals, anti-goals and acceptance list. Then `superpowers:finishing-a-development-branch`.

---

## Follow-up (milestone 2, not planned here)

- `NEMInitialPower <: PSI.InitialConditionType` with its value and update methods, created in `construct_device!`, `requires_initialization` kept `false` (D3, R4).
- Update methods on `DecisionModel{NEMClosedLoopDispatchProblem}` that recompute the state-dependent parameters from `SimulationState` with the AEM kernels (R2, R3), and the `true` branch of the two C6 accessors.
- Closed-loop tests replacing the deleted `state_update_equivalence` group.
- Candidates left open by milestone 1: drop the `energy_offer` series (widths from the raw bid series); upstream `ConstraintCoefficientParameter`.

## Self-review notes

- Spec coverage: G1 (Tasks 3-14, A4), G2 (3-13, 16-18), G3 (14, 19), G4 (2, A4), G5 (19), G6 (16-18), G7 (15; tie-break, loss and FCAS slopes untouched), D1 rows (3-12), D2 (13-14), D3/D5/C6 seams (19), D4 (1, 3-10), D6 (15-18), D7 (2, 6, 11, 14, 20), acceptance 1-8 (22).
- Open risks that need the user if they materialise: Task 8 enablement flips, Task 15 or 18 tied-vertex moves, Task 0 price-constancy failure on real data, the 20 s budget.
