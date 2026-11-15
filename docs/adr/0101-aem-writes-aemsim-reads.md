# 0101. AEM writes every replay input; AEMSim only reads the System

## Status

Accepted. Supersedes the derived-input parts of [0095](0095-typed-nem-system.md) (`NEMDispatchInputs`
written by AEMSim), [0096](0096-per-step-state-updates.md) (custom per-step parameter updates) and
[0098](0098-precomputed-observed-state-inputs.md) (series precomputed by AEMSim before the build). The
replay interface of [0092](0092-psi-shaped-replay-interface.md) and the key types of
[0100](0100-one-key-type-per-family-and-role.md) stay in force.

## Context

AEM builds a PowerSystems `System` from NEMWEB data and AEMSim builds and steps a PowerSimulations (PSI)
model of NEMDE from it. Before this decision the split was blurred:

- AEMSim finished preparing the System before the build. `prepare_replay!` wrote derived series, replaced
  and removed series, removed and re-added a service, switched availability and recorded exclusions in
  `ext`.
- Ten AEMSim `update_container_parameter_values!` overrides were never run in production: they handed
  back to PSI's stock update under `ObservedState`.
- Band prices were per-step cost parameters (the fork's `TimeSeriesCostParameter`), which re-set the
  whole objective at every interval.

PSI's design (mapped in `docs/psi-anatomy.md`) is that the System is fully prepared by its builder before
a model is constructed, the model only reads it, and per-step updates are PSI's own.

## Decision

### 1. Ownership and the builder stage

AEM writes every input the model reads, once, in a private stage `_set_replay_inputs!(sys)` that
`nem_system(db, NEMDEConfiguration(); date_range)` runs last. AEMSim never writes to the System: no PSY
or IS mutator, no `add_time_series!`, no `set_available!`, no `ext` write and no `with_units_base`
toggle anywhere in `AustralianElectricityMarketsSimulations/src/`.

The stage order is fixed:

1. resolution check: every single time series is at the five-minute dispatch interval;
2. energy offer curves `energy_offer[_decremental]`, band prices referred to the reference node by the
   side's loss factor and rounded;
3. MNSP fixed-loading value and invocation series;
4. dispatch ramp rates (the lesser of bid and telemetry) and AGC ramp rates;
5. observed-state inputs (initial MW and fixed-loading targets, the former "seeds");
6. FCAS effective offers and regulation ramping limits, in per-unit of the system base;
7. tie-break scales and the `EnergyTieBreak` service;
8. loss-demand coefficients of each loss-modelled interchange;
9. constraint availability (section 3);
10. band prices as typed day-constants (section 4);
11. the forecast transform into five-minute windows; no series may be added after it;
12. the record of the unavailable devices and services the inputs were derived for.

One writer per series name; no series is written by one stage and replaced or removed by a later one.
The kernels (`src/derivations/`) are scalar functions of `Float64` inputs and an `NEMUnitState`; the
writers (`src/system/replay_inputs/`) loop them over the range. Milestone 2 will call the same kernels
on solved state, so the two modes cannot drift apart.

Availability is part of the data the inputs were derived from: FCAS effective offers exist only for
available units, tie-break membership and loss-demand terms sum available components, and constraint
availability follows device availability. `validate_template` therefore refuses a System whose device
or service availability changed after the stage, naming each changed component; set availability
before `nem_system` builds the replay inputs, or rebuild.

### 2. Replay range

Every caller builds `date_range = first(steps):5min:(last(steps) + 10min)`. The replay intervals are all
stamps but the last two; they equal the forecast initial times less the last, and `replay_intervals(sys)`
returns them. `nem_system` requires at least three stamps and refuses a range whose replay intervals span
two trading days (04:00 boundary) or two financial years (00:00 on 1 July): the Market Price Cap, and
therefore every penalty price, and the marginal loss factors change there, and band prices are fixed per
trading day. The two trailing stamps may cross either boundary.

Known limitation: a `Simulation` can step one forecast window beyond `replay_intervals(sys)` without the
range rule checking it. No caller does this.

### 3. Exclusions: data facts, modelling choices and template facts

- **Data facts**, decided by AEM: a constraint never invoked over the replay intervals, or whose
  contributing devices are all unavailable, is built with `available = false` and recorded in the build
  report's `unavailable_constraints` (`never_invoked` takes precedence over `no_available_device`). A
  constraint with an unresolved component stays a build error.
- **Modelling choices**, in the template: `template_nemde(; exclude_constraints)` sets a
  `"filter_function"` attribute on the aggregated `ServiceModel(GenericConstraint, LinearFactorLimit)`,
  which PSI's expansion honours.
- **Template facts**, in `validate_template`: a constraint that involves something the template does not
  model (an FCAS service or a device type) has its per-name service model deleted from the model's copy
  of the template, as PSI does for empty device models. Blocked constraints throw.

One pure predicate, `replay_skipped_constraints(sys, template)`, feeds both the pruning and the batch
report. `exclude_unmodeled_services!`, `prepare_replay!` and their `ext` records are removed. A build
report stored before `unavailable_constraints` existed throws on read rather than defaulting.

### 4. Prices are typed day-constants

Energy, FCAS and MNSP band prices are written by AEM as `band_prices::NTuple{10, Float64}` on
`NEMEnergyBid`, `NEMFCASBid` and `NEMMNSPBid` (energy prices referred and rounded; shorter curves padded
with `0.0`), and `nem_system` throws when a unit's prices vary within the replay range. AEMSim adds the
band costs once, as invariant objective terms, so the objective has no variant contributors and PSI never
re-sets it between steps. No `TimeSeriesCostParameter` is left in AEMSim. MNSP curves keep all ten bands:
band `k` is always `PRICEBAND<k>`, zero-width where `BANDAVAIL` is zero.

### 5. Non-invoked generic constraints are free rows

Every generic constraint row is an `Interval` row whose bounds follow `GenericConstraintInvocationParameter`,
a `ConstraintBoundParameter` of the pinned PSI fork read from the `invoked` series: at a non-invoked
interval the row is free, exactly as a constraint absent from that interval's dispatch. The slack of an
elastic constraint is priced at a constant CVP factor times the Market Price Cap. A recurrent build no
longer needs `use_slacks = true`.

The plan's invocation mask (an unpriced relaxation `c_t (r+ - r-)` with `c_t = 1 - invoked_t`) was
implemented and reverted (`84aefa5`): it realised the same primal but moved degenerate duals and added
columns. Free rows (`c839c46`) were reverted with it, then re-applied as the final form, which needs no
extra column.

### 6. Per-step coefficient updates

The only per-step coefficient updates are the interconnector loss equation's demand term, the FCAS
trapezium slopes and the tie-break scales (band-width ratios, which change with rebids), through the
fork's `ConstraintCoefficientParameter`, and the generic-constraint invocation bounds, through its
`ConstraintBoundParameter`. All are refreshed by PSI's stock time-series update; AEMSim defines no
`update_container_parameter_values!`, `update_parameter_values!` or `_update_parameter_values!` method. The
one exception is the shared generic constraint containers, whose update reads every constraint's
series ([0103](0103-aggregated-generic-constraint-containers.md)).

### 7. The problem type selects the replay mode

`NEMDispatchProblem` (observed state) and `NEMClosedLoopDispatchProblem` (closed loop) are both
`<: AbstractNEMDispatchProblem <: PSI.DefaultDecisionProblem`; the template carries no mode.
`DecisionModel{M}` fixes the horizon, resolution and interval at one dispatch interval and rejects them
and `ext` as keywords, so PSI's auto-transform never adds a second forecast set; it records
`ext["closed_loop"]`. Milestone 1 refused the closed-loop type in `validate_template`; milestone 2 implements
it ([0102](0102-closed-loop-replay.md)).

The two raw state quantities, unit initial MW and MNSP initial flow, are read through one accessor each
(`_initial_mw_accessor`, `_mnsp_initial_flow_accessor`), given the `closed_loop` flag read once per build
step. The open-loop branch returns the observed-state parameter as a `JuMP.AffExpr`; milestone 2 fills the
closed-loop branch from PSI initial conditions without touching the constraints that use the value. The
accessors are factories returning `(name, t) -> JuMP.AffExpr`, so the parameter container is fetched once
per build step, not per cell. Fixed loads, ramps and FCAS limits are state-dependent parameters in both
modes and need no accessor.

### 8. Units

- FCAS kernels are unit-agnostic. The writer divides raw MW inputs by the base on read; a pure-MW
  kernel run picked an alternate optimal vertex among ties at an equal objective.
- `fcas_preconditions_ok` uses `Inf` for "no energy availability limit"; NaN data still fails.
- No display-unit toggling anywhere: loss demand reads raw fields.

### 9. No duplicates, no fallbacks

AEMSim imports AEM's readers and kernels; no rule has two implementations. AEMSim's
`effective_regulation_enablement` had no caller and was deleted; the effective-offer writer applies the
AGC enablement limits through `scale_fcas_trapezium`, which treats a zero telemetered limit as absent.
Missing cache columns
or tables fail with a repopulate remedy, never a fallback.

### 10. Degenerate duals are not gated individually

At degenerate points LP duals are not unique. At 2026-06-04 04:15 SA1 the twin R6 and R60 requirement
rows (identical right-hand side and energy terms) leave the two prices anywhere on a face [4.5384, 4.89]
at a constant sum; rebuilding the LP picks either end. NEMDE resolves FCAS ties by its own solver path.
The comparison gate (`compare.jl --invariants`) therefore gates variables, the objective (to the solver's
`1e-8` relative MIP gap), the energy price duals and the per-(interval, region, direction) sum of FCAS
requirement duals, and reports the rest. The same mechanism made a stock-simulation test assert two
vertices of one RAISEREG face (a requirement exactly equal to the only provider's capacity, price
anywhere in [band price, CVP x MPC]); its fixture now keeps the requirement below capacity.

A deterministic post-solve dual selection on the fixed-integer LP is a follow-up, with its own ADR and a
multi-day NEMDE check.

## Consequences

- The replay interface is exactly `nem_system -> DecisionModel(NEMDispatchProblem, template, sys) ->
  Simulation -> build! -> execute!`; `scripts/replay_batch_worker.jl` uses it.
- Systems built before this decision lack the replay inputs and the availability record and must be
  rebuilt.
- The System build absorbs the work `prepare_replay!` did, so the warm build budget is spent there.
- Removed: `prepare_replay!`, `set_effective_offers!`, `exclude_unmodeled_services!`, `NEMDispatchInputs`,
  `NEMFCASInputs`, `SimulatedState`, `ObservedState`, the per-step overrides, `get_initial_mw`,
  `effective_regulation_enablement` and the band-price and slack-cost parameters.
- Fork-only PSI features this relies on, candidates for upstreaming: `ConstraintCoefficientParameter`,
  `ConstraintBoundParameter`, and `add_parameters!(...; meta, time_series_name)`.
- The problem-type switch leaves room for milestone 2 (closed-loop replay through PSI initial conditions,
  `requires_initialization` kept `false`, update methods on `DecisionModel{NEMClosedLoopDispatchProblem}`).

## Market correctness

| Decision | Source |
| --- | --- |
| Band prices fixed for the trading day (energy, FCAS, MNSP) | AEMO *Spot Market Operations Timetable* v1.12 (effective 2025-12-02) s2.1: "Price bands in bids for Day 0 cannot be changed after 12:30 Day -1" (NER 3.8.5, 3.8.6, 3.8.6A, 3.8.7, 3.8.7A, 3.8.7B; rebidding 3.8.22). AEMO *FCAS Model in NEMDE* s2: "Prices are defined for a trading day, and MW quantities are defined for each trading interval". |
| A non-invoked constraint is absent from that interval's dispatch | AEMO *Constraint Formulation Guidelines* s8.1. |
| Constraint violation penalty is CVP factor x Market Price Cap | AEMO *Schedule of Constraint Violation Penalty Factors* v8.0. |
| FCAS price ties resolved by solver path | AEMO *Schedule of Constraint Violation Penalty Factors* v8.0 item 53; AEMO *Constraint FAQ* Q3.19. |

No bound, constraint or cost term changed in this milestone beyond sections 4 and 5. Section 4 changes
how the cost enters the objective, not its value. Section 5 realises the guideline exactly.

## Verification

Gate: `compare.jl --invariants --mask-gc-slacks --report-only 'FCASCapacityVariable|FCASOfferBandVariable|FCASSideCapacityVariable|MNSPLinkBandVariable'`
against a local reference captured at the handover head (`1877ac1`, Tasks 0 to 18), with the milestone head
`52aa442` as candidate. Real runs replay 2026-06-04 from 04:05 (Apple Silicon, 32 GB, HiGHS `mip_rel_gap` 1e-8).

| Measure | Reference `1877ac1` | Milestone 1 `52aa442` |
| --- | --- | --- |
| Mock gate (3 intervals) | | `GATE PASS`, max abs gap 0.0, no reported dual difference |
| Real 1 h gate (12 intervals) | | `GATE PASS`, max abs gap 4.9e-13, no reported dual difference |
| Real day gate (288 intervals) | | `GATE PASS`, max abs gap 2.0e-11 |
| Warm System build, one trading day | 9.49 s (+ 0.23 s prepare) | 6.32 s (+ 0.22 s prepare) |
| Warm model build, one trading day | 2.55 s | 2.25 s |
| Warm total against the 20 s budget | 12.3 s | 8.8 s |
| Key types (mock / real) | 111 / 117 | 111 / 117 |
| JSON round-trip of a `NEMDEConfiguration` System | | forecasts, replay intervals, tie-break service and scales, band prices, build report and availability record preserved |

On the real day, report-only FCAS capacity and band variables moved by at most 0.19 MW (price-tied FCAS
offers, dispatched by solver path) and 41 non-gating duals moved, all at degenerate points: FCAS
joint-capacity rows, three regulation requirement rows and four one-term zero-right-hand-side unit
constraints parallel to a variable bound. The NEMDE comparison of the real day is identical to the
reference within 1e-15 on every metric:

| Metric (absolute gap to NEMDE) | n | MAE | RMSE | max |
| --- | --- | --- | --- | --- |
| dispatch (MW) | 152064 | 0.011696 | 1.0131 | 244.0 |
| energy price (\$/MWh) | 1440 | 0.034695 | 0.33342 | 6.7792 |
| FCAS price (\$/MWh) | 14400 | 0.0017119 | 0.052474 | 2.5276 |
| interconnector flow (MW) | 1728 | 0.21873 | 5.8109 | 233.81 |
| interconnector losses (MW) | 1728 | 0.0059055 | 0.10535 | 3.5660 |

The maxima equal those of the batch statistics on the original machine (head `918ce0a`), which confirms the
cache and environment reproduce it. The full root and Simulations suites pass; the batch runner's memory
sampler needs Linux `/proc`, so the batch statistics and its `scripts/` tests were not run here.
