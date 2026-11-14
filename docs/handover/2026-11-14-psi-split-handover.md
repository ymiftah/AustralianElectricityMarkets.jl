# Handover: AEM/AEMSim split along PowerSimulations' design (milestone 1)

> **Temporary.** Delete the whole `docs/handover/` folder before PR #237 is merged. Durable decisions
> belong in ADR 0101 (Task 21).

This file hands milestone 1 of the AEM/AEMSim refactor to an agent on a **different machine**. That
machine has none of the original machine's validation outputs: no baseline captures and no
`aem_validation` folder. **Your instruction is to finish the plan so that replay results match AEMO's
published NEMDE outcomes as closely as possible, with an API aligned on PowerSimulations (PSI).**
Exact parity with an earlier code revision is not required (user decision, 2026-11-14).

## 1. Where things are

| Item | Location |
| --- | --- |
| Branch | `refactor/psi-split` on `origin` (ymiftah/AustralianElectricityMarkets.jl) |
| Draft PR | #237, base `perf/key-types` (itself PR #236) |
| PSI fork pin | `ymiftah/PowerSimulations.jl` branch `feat/constraint-bound-parameter` at `3d504be45c4e6a4b53aededaf6dc8d88f328c35b` (three commits on `81c0259d1`: `ConstraintBoundParameter`, an infinite-bound numerical check fix, an infinite-bound MOF/LP export fix). Pinned in `AustralianElectricityMarketsSimulations/Project.toml`, its `test/Project.toml` and `docs/Project.toml`. |
| Design (authoritative intent) | `docs/handover/2026-11-13-aem-aemsim-psi-split-design.md` |
| Implementation plan (Tasks 0-22) | `docs/handover/2026-11-13-aem-aemsim-psi-split-plan.md` |
| PSI reference map | `docs/psi-anatomy.md` |
| FCAS dual-tie analysis | `docs/handover/2026-11-14-fcas-dual-tie-analysis.md` |
| Baseline/gate tooling | `AustralianElectricityMarketsSimulations/test/baseline/{snapshot,capture,compare}.jl`, tests in `…/test/baseline_tools.jl` |
| Batch replay and statistics | `scripts/replay_batch.jl`, `scripts/simulation_statistics.py`, `scripts/README.md` |

The plan and design were written assuming a baseline captured on the old machine. Read sections 4
and 5 here before following any plan step that names `$B` or "the baseline".

## 2. What is done (Tasks 0-18)

Every task below was implemented by a subagent, reviewed by an Opus subagent, and fixed until clean.

| Task | Result |
| --- | --- |
| 0 | Baseline capture/compare tooling (`capture.jl`, `compare.jl`, 1e-9 gate) |
| 1 | `NEMUnitState` and the pure state rules in AEM; private builder stage `_set_replay_inputs!(sys)` called by `nem_system(db, NEMDEConfiguration(); date_range)` |
| 2 | The 10 dead AEMSim per-step `update_container_parameter_values!` overrides deleted: per-step updates are PSI's own |
| 3-10 | Every derived input written once by AEM inside the stage (`src/system/replay_inputs/`, kernels in `src/derivations/`): energy offers, MNSP fixed loads, ramps and AGC ramps, observed-state inputs, FCAS effective offers and ramping limits, tie-break scales and the `EnergyTieBreak` service, loss-demand coefficients |
| 11 | Fixed series names; `NEMDispatchInputs`, `NEMFCASInputs`, `set_effective_offers!` deleted |
| 12 | Forecast transform at the end of the stage; `replay_intervals(sys)`; one trading day and one financial year per System (`_check_replay_range`) |
| 13 | Constraint availability decided by AEM as data (`get_unavailable_constraints`) |
| 14 | Checks in `PSI.validate_template`; `prepare_replay!` and `exclude_unmodeled_services!` removed; `replay_skipped_constraints(sys, template)`; batch worker on the plain `nem_system -> DecisionModel -> Simulation -> build! -> execute!` sequence |
| 15 | Superseded by 18 (two attempts reverted, then re-applied; see section 6) |
| 16-17 | Energy and FCAS band prices as typed day-constants (`band_prices` on the bid structs) in the invariant objective |
| 18 | MNSP band prices as day-constants (MNSP curves keep all 10 bands); generic constraints as `Interval` rows freed per non-invoked interval through the fork's `ConstraintBoundParameter` ("option E"); constant CVP x MPC slack cost; **no `TimeSeriesCostParameter` left in AEMSim**; new invariants gate |

Head after Task 18: `cdca8ad` (check `git log` on the branch; later commits may include the Task 18
review fixes).

## 3. What remains

1. **Task 18 review fixes**, if the Opus review of `872e989..cdca8ad` found any. Read the PR and the
   last commits.
2. **Task 19.** `AbstractNEMDispatchProblem`, `NEMDispatchProblem`, `NEMClosedLoopDispatchProblem`, the
   closed-loop guard (`closed-loop replay is not implemented`), constructor keyword rules and the two
   state accessors. See the plan.
3. **Task 20.** Remaining dead-code removals.
4. **Task 21.** ADR 0101, CHANGELOG, AGENTS.md and READMEs. ADR 0101 must record every decision in
   section 6.
5. **Task 22.** Milestone acceptance, **with the acceptance redefined in section 5**.
6. **Follow-up after milestone 1 (user request).** Post-solve **dual selection**: pick a
   deterministic optimal dual vertex on the fixed primal or fixed-integer LP with an explicit rule, so
   FCAS prices at degenerate points do not depend on LP structure. It needs its own ADR and a
   multi-day NEMDE check.

The Task 18 review (Opus) approved `872e989..cdca8ad`. Its minor findings are yours to fix first,
in one small commit:

- **CHANGELOG.** `CHANGELOG.md:18`'s MNSP entry says "only the generic-constraint slack cost remains
  one". That is stale, because option E removed it. Delete the clause.
- **Units string.** The `NEMFCASBid.offer_curves` field docstring (`src/types/nem_offer_cost.jl:112`)
  still says "\$/MW". It should be "\$/MWh".
- **Key-name check.** `…Simulations/src/formulations/generic_constraints.jl:~382`: add
  `_constraint_key(gc, :invoked, NEM_CONSTRAINT_SERIES.invoked)` next to the `:rhs` check, so a
  static or misnamed `invoked` field fails with the package's clear message.
- **`compare.jl`.**
  - List the `invariants` and `report_only` keywords on `compare_snapshots`'s signature line.
  - Give `reported_dual_differences` its `# Arguments` and `# Returns` sections.
  - Add a unit test for report-only keys being excluded from the worst list.
  - In invariants mode, assert the energy dual and the derived FCAS-sum keys exist when
    `input/fcas_requirements` is non-empty, so those gates cannot vanish silently.
  - The objective gate tolerance `_STATS_RTOL = 1e-9` is tighter than the solver's 1e-8 relative MIP
    gap, so real_day can fail on solver noise; 2026-06-04 17:40 differs by 5.6e-9. Use the MIP gap
    as the objective tolerance and record it.
- **Coverage.**
  - Assert `has_variant_contributors == false` on a full replay template, not only the loss test.
  - Solve one step in `stock_simulation.jl:483-498`, a recurrent build without slacks, to prove the
    free rows work without slacks.

Known open items to fold into 19-22 (from reviews):

- **Build time.** One trading day, warm: System build 22.95 s, model build 6.33 s, skipped report
  0.52 s, about 29.8 s in total. CP1 (after Task 14) was already 28.2 s, because the old 7.1 s
  `prepare_replay!` work moved into the System build. Task 18 added about 1.6 s.
  - The 20 s budget (System plus model) is not met.
  - Task 22 A3: profile `_set_replay_inputs!` per writer.
  - Levers: stop writing the `energy_offer` series and read band widths from the raw bid series.
    Then the MNSP remove plus re-add of the supplemental attribute in `_set_band_prices!`
    (`src/system/replay_inputs/prices.jl:241-242`).
- **FCAS enablement is report-only.** It is not gated against the reference. A real FCAS dispatch
  regression would surface only through the objective, the FCAS price sums and the per-unit NEMDE
  comparison (`entity_errors.csv`), so check the latter at every checkpoint.
- **Tutorial.** `docs/literate/tutorials/nemde_aem.jl` still hand-builds a System and lacks the derived
  series. Rewrite it on `nem_system` on the mock hive before the docs build.
- **Step-range limitation.** A `Simulation` can step one forecast window beyond
  `replay_intervals(sys)` without the C4 range rule checking it. Document it in ADR 0101 and in the
  docstrings; no caller does this.
- **Edge cases in `validate_template`.** The all-excluded case loses the exclusion attribute on the
  expanded template. The blocked-constraint throw inside `PSI.validate_template` is untested.
- **Range-rule errors.** The messages lack the offending days or years and a remedy.
- **JSON round-trip coverage.** No test round-trips a `tie_break_scale_*` series, so cover it in
  Task 22 A7.
- **Fork upstreaming.** `ConstraintCoefficientParameter` and `ConstraintBoundParameter` are fork-only
  and are candidates.

## 4. Environment on the new machine

- Julia 1.13 workspace; `julia --project=AustralianElectricityMarketsSimulations/test …` for
  Simulations work. One Julia process at a time if memory is limited (the original machine had 14
  GB). Precompile alone after editing `src/`.
- Formatter Runic via `pre-commit run -a`. AGENTS.md has the standards: explicit `return`, reference
  docstrings that never cite ADRs, no em-dashes, CHANGELOG `[Unreleased]` kept current.
- Optimisation model changes must be checked against AEMO documentation (AGENTS.md "NEM correctness").
  The `nem-expert` skill and its references were on the original machine in `~/.agents/skills/`; if
  absent, use AEMO's published documents directly. Citations already established:
  - **Band prices fixed for the trading day.** AEMO *Spot Market Operations Timetable* v1.12
    (effective 2025-12-02) §2.1: "Price bands in bids for Day 0 cannot be changed after 12:30 Day -1"
    (NER 3.8.5, 3.8.6, 3.8.6A, 3.8.7, 3.8.7A, 3.8.7B; rebidding 3.8.22). AEMO *FCAS Model in NEMDE*
    §2: "Prices are defined for a trading day, and MW quantities are defined for each trading
    interval".
  - **A non-invoked constraint is absent from that interval's NEMDE run.** Constraint Formulation
    Guidelines §8.1. The violation penalty is CVP factor x Market Price Cap, from the Schedule of
    Constraint Violation Penalty factors.
  - **FCAS ties are resolved by solver path.** CVP Factors v8.0 item 53 and Constraint FAQ Q3.19:
    price-tied FCAS offers are "dispatched randomly … based on how the LP optimization process in
    NEMDE approached that solution".

### Data to populate

Replays read only the local NEMWEB cache (`~/.nemdb_cache/<TABLE>/archive_month=YYYY-MM-01/`). A
`NEMDEConfiguration` System needs every table of `table_requirements(NEMDEConfiguration())`, for every
archive month the replay range touches. Today that list is:

| Group | Tables |
| --- | --- |
| Regional network | `INTERCONNECTOR`, `INTERCONNECTORCONSTRAINT`, `DISPATCHREGIONSUM`, `DUDETAIL`, `DUDETAILSUMMARY`, `STATION`, `STATIONOPERATINGSTATUS`, `GENUNITS`, `DUALLOC`, `BIDDAYOFFER_D`, `BIDPEROFFER_D`, `DISPATCHLOAD` |
| Prices and FCAS | `DISPATCHPRICE`, `DISPATCH_FCAS_REQ` (archive months up to 2025-05), `DISPATCH_FCAS_REQ_CONSTRAINT` (from 2025-06) |
| Constraints | `DISPATCHCONSTRAINT`, `GENCONDATA`, `SPDCONNECTIONPOINTCONSTRAINT`, `SPDREGIONCONSTRAINT`, `SPDINTERCONNECTORCONSTRAINT` |
| Losses and MNSP | `LOSSMODEL`, `LOSSFACTORMODEL`, `MNSP_INTERCONNECTOR`, `MNSP_DAYOFFER`, `MNSP_BIDOFFERPERIOD`, `DISPATCH_MNSPBIDTRK`, `DISPATCHINTERCONNECTORRES` |

Always confirm against the code, since the list can change:

```julia
using AustralianElectricityMarkets, AustralianElectricityMarketsData, Dates
db = aem_connect()
tables = table_requirements(NEMDEConfiguration())
for month in (Date(2026, 1, 1), Date(2026, 3, 1), Date(2026, 4, 1), Date(2026, 5, 1), Date(2026, 6, 1))
    for t in tables
        populate(db, t, month, lastdayofmonth(month))
    end
end
```

`populate` is idempotent. Pass `force_new = true` only after a `_TABLE_SPECS` column change, and add
no fallbacks for missing columns: repopulate instead. Registration and slowly changing tables such as
`DUDETAIL`, `GENUNITS`, `STATION`, `DUALLOC`, `LOSSFACTORMODEL`, `MNSP_INTERCONNECTOR` and
`INTERCONNECTOR` need archive months covering the replay date. Bids (`BIDDAYOFFER_D`) for a trading
day starting 04:05 belong to that day's archive month. Replays are supported only from 1 October 2021
(5-minute settlement).

### Mock data

The four `Pkg.test` suites and `capture.jl --hive mock` use generated mock parquet data
(`test/fixtures/mock_data.jl`) and need no cache.

## 5. Acceptance on the new machine (replaces "match the baseline within 1e-9")

User decision: **closeness to NEMDE is the quality criterion.** Baseline dispatch parity is not
required where results stay as close to NEMDE or closer. LP duals at degenerate points, such as twin
R6/R60 requirement rows, are not unique (see the FCAS analysis) and are never gated individually.

### Step 1: re-create a local reference at the handover head

Before changing anything, on the new machine at the branch head:

```bash
T=AustralianElectricityMarketsSimulations/test
R=<results>/$(date +%F)_compare_local-reference_$(git rev-parse --short HEAD)
julia --project=$T $T/baseline/capture.jl --hive mock --start 2025-01-01T00:05:00 --intervals 3 --out $R/mock
julia --project=$T $T/baseline/capture.jl --hive $HOME/.nemdb_cache --start 2026-06-04T04:05:00 --intervals 12 --out $R/real_1h
julia --project=$T $T/baseline/capture.jl --hive $HOME/.nemdb_cache --start 2026-06-04T04:05:00 --intervals 288 --warm --out $R/real_day
julia --project=$T scripts/replay_batch.jl --first 2026-06-04 --last 2026-06-04 --hours 3 --hive $HOME/.nemdb_cache --output <results>/batch_local-reference
python3 scripts/simulation_statistics.py <results>/batch_local-reference
```

The 2026-06-04 batch `errors.csv` should reproduce the original machine's CP2 numbers (table below)
to within solver noise. If it does not, stop and investigate the data or the environment before any
code change. That makes it a cross-machine check of data and environment.

**Reference numbers, 2026-06-04, 288 intervals, head `918ce0a`/`cdca8ad` (CP2 on the original
machine).** Absolute errors against NEMDE:

| Metric | n | p90 | p95 | p99 | max | MAE | RMSE |
| --- | --- | --- | --- | --- | --- | --- | --- |
| dispatch_mw (MW) | 152064 | 0.0 | 1.42e-14 | 0.00036 | 244.0 | 0.011945 | 1.0137 |
| energy_price ($/MWh, ROP) | 1440 | 0.000109 | 0.000318 | 1.3124 | 6.7792 | 0.037306 | 0.33938 |
| fcas_price ($/MWh) | 14400 | 1.1e-16 | 8.9e-16 | 1.49e-06 | 2.5276 | 0.001646 | 0.05181 |
| interconnector_flow_mw (MW) | 1728 | 0.00368 | 0.00455 | 0.2564 | 233.81 | 0.22362 | 5.8185 |
| interconnector_losses_mw (MW) | 1728 | 0.000265 | 0.000466 | 0.01289 | 3.5660 | 0.005827 | 0.10521 |

The pre-refactor baseline (`79162ba`) on the same day had: dispatch identical; energy_price MAE
0.037457, p90 0.000117; fcas_price MAE 0.001742; flow p99 0.3901; losses p99 0.0220. Task 18 is
therefore as close or closer on every aggregate. One interval is worse: 17:40, a MIP-gap tie with
N-Q-MNSP1 at 9.00 against 9.24 MW and NSW1/VIC1 price off by about 0.1 $/MWh.

### Step 2: gate each later task

- **Per-task quick gate** against your local reference:

  ```bash
  compare.jl $R/mock $C/mock --invariants --mask-gc-slacks --report-only 'FCASCapacityVariable|FCASOfferBandVariable|FCASSideCapacityVariable|MNSPLinkBandVariable'
  ```

  Run the same for `real_1h`. Gating then covers:
  - variables, aux and expressions, except the report-only ones;
  - the objective;
  - energy price duals;
  - per (interval, region, direction) FCAS price sums.

  Tasks 19 and 20 should not change the LP, so expect `GATE PASS`. Report-only differences are
  listed. Explain them, never ignore them.
- **Checkpoint and final acceptance** (Task 22 A1/A2). Run the batch on the cross-check days below.
  No `errors.csv` cell may be worse than your local reference beyond solver noise, and closer is
  better. Compare per metric: dispatch_mw, energy_price, fcas_price, interconnector_flow_mw,
  interconnector_losses_mw, and per-unit FCAS enablement where available (`entity_errors.csv`). For
  every cell that diverges from the reference, tabulate reference, candidate and NEMDE, and say which
  is closer.
- All other Task 22 items stand:
  - A3: build ≤ 20 s, currently failing (see section 3);
  - A4: the no-writes, no-custom-updates and no-`TimeSeriesCostParameter` greps;
  - A5: the closed-loop guard;
  - A6: key types, now 111 mock and 117 real against 122/128 before;
  - A7: serialisation;
  - A8: all suites, the real-data suite, docs build, Linting;
  - A9: an Opus whole-branch review.

## 6. Decisions and rulings to carry into ADR 0101

1. **Ownership.** AEM writes every input the model reads, once, in `_set_replay_inputs!`, and AEMSim
   never mutates the System. The ADR records the departures from ADR 0095, 0096 and 0098.
2. **Mode switch.** The mode is selected by the problem type (`NEMDispatchProblem` /
   `NEMClosedLoopDispatchProblem`), not a template boolean (user decision). Milestone 2 is closed-loop
   replay through PSI initial conditions.
3. **Prices as day-constants.** Energy, FCAS and MNSP band prices are typed day-constants in the
   invariant objective, so the objective is fully invariant. The citations are in section 4.
4. **Non-invoked generic constraints.** A non-invoked generic constraint is a free `Interval` row
   through the fork's `ConstraintBoundParameter`, and the slack cost is constant CVP x MPC. This
   realises CFG §8.1 exactly. Two earlier attempts moved degenerate duals only:
   - an unpriced masked relaxation (`84aefa5`), reverted;
   - free rows (`c839c46`), reverted and then re-applied.
5. **MNSP curves keep all 10 bands.** Band k is PRICEBAND k. Empty bands are zero-width.
6. **Degenerate FCAS duals.** At 2026-06-04 04:15 SA1, the twin R6/R60 requirement rows leave
   individual prices on a face [4.5384, 4.89] at a constant sum. NEMDE resolves this by solver path.
   Acceptance is redefined accordingly (section 5).
7. **Kernels and units.**
   - FCAS kernels are unit-agnostic. The writer divides raw MW inputs by the base on read: a pure
     MW version picked an alternate optimum.
   - `fcas_preconditions_ok` uses `Inf` for "no energy availability limit"; NaN data fails.
   - No display-unit toggling anywhere: loss demand reads raw fields.
8. **No duplicates or fallbacks.** No verbatim duplicates across AEM/AEMSim: AEMSim imports AEM's
   shared readers. No silent fallbacks for missing data.
9. **Toy fixtures.** Toy fixtures follow the production convention of one trailing series point
   beyond the last step.
10. **Replay range.** The replay range is the System range: one trading day and one financial year,
    trailing two stamps excluded.

## 7. Cross-check days with existing results on the original machine

These days already have replay outputs on the original machine, so the user can compare results from
the new machine later. They live under `/run/media/simba/Store/aem_validation/` there.

| Day | Results on the original machine | Code revision |
| --- | --- | --- |
| **2026-06-04** | `2026-11-13_batch_psi-split-baseline_79162ba`, `2026-11-14_batch_psi-split-cp1_cb642de`, `2026-11-14_batch_psi-split-cp2_918ce0a`, plus capture folders `2026-11-1[34]_compare_psi-split-*` | pre-refactor baseline, Task 14, Task 18 |
| **2026-01-06** | `overnight_10h_20261027T120955Z/2026-01-06`, `day_2026-01-06_{3618b36,863ea1d,c411fda}` | older revisions (October to November 2026) |
| **2026-04-13** | `day_2026-04-13_a393e01`, `rerun_2026-04-13_{f873305,stock,stock2}` | older revisions |
| **2026-03-06** | `overnight_10h_20261027T120955Z/2026-03-06` | older revision |
| **2026-05-22** | `overnight_10h_20261027T120955Z/2026-05-22` | older revision |

2026-06-04 is the primary day: its numbers are in section 5. For the others, run the batch on the new
machine and keep `simulation_statistics/` outputs, named with the day and commit, for the user to
compare. Populate the archive months 2026-01, 2026-03, 2026-04, 2026-05 and 2026-06 (section 4).

## 8. Working method that worked

- **Subagent-driven.** One implementer per task, then an Opus spec-and-quality review, then fix rounds
  with scoped re-reviews. Integration-heavy tasks went to Sonnet implementers, because Haiku blocked
  twice.
- **Test discipline.**
  - Run the full root and full Simulations suites before every commit: named groups alone missed
    regressions.
  - Writer tests and their throw contracts live in the root suite on a `nem_system` mock build.
  - Never remove derived series and re-run the whole stage, which is add-only.
- **Stop rule.** Stop and report, never loosen a gate, when a result moves for an unexplained reason.
  Decide degenerate-tie cases on NEMDE closeness.
