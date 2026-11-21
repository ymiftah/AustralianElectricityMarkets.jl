# 0109 AEMSim owns its PSI extensions: constraint targets and the area-balance slack

## Status

Accepted. Supersedes the fork-parameter bullet of [0101](0101-aem-writes-aemsim-reads.md) (per-step updates use
`ConstraintCoefficientParameter` and `ConstraintBoundParameter`), and the "area-balance slack is the network model's
`slack_cost`" bullet of [0023](0023-elastic-fcas-rows-and-area-balance-cvp.md). Builds on
[0100](0100-one-key-type-per-family-and-role.md).

## What

- AEMSim defines `NEMConstraintCoefficientParameter` and `NEMConstraintBoundParameter`, abstract types under the new
  `NEMFloatTimeSeriesParameter <: PSI.TimeSeriesParameter`, which always store `Float64`. The five concrete parameter
  types keep their names (`LossDemandCoefficientParameter`, `FCASUpperSlopeParameter`, `FCASLowerSlopeParameter`,
  `TieBreakScaleParameter`, `GenericConstraintInvocationParameter`), so result keys do not change.
- AEMSim owns the target registry that applies those parameters to the rows they scale or bound. The fork's
  `ConstraintCoefficientParameter`, `ConstraintBoundParameter` and `NetworkModel.slack_cost` are no longer used.
- AEMSim owns the area-balance slack: `AreaBalanceSlack` is an exported variable keyed by `PSY.Area` with metas
  `"deficit"` and `"surplus"`, priced at `AREA_BALANCE_CVP_FACTOR` (150) times the Market Price Cap. It enters the
  `ActivePowerBalance` expression with sign +1 (deficit) and -1 (surplus), as PSI's `SystemBalanceSlackUp` and
  `SystemBalanceSlackDown` do.
- `_add_area_balance_slacks!` is called idempotently from the argument stage of every AEMSim formulation that writes to
  the area balance (`NEMDispatch`, storage, FCAS market, tie-break, generic constraints, interconnector losses). It
  creates the slacks once per container. For an `AreaBalancePowerModel` whose `"area_balance_slacks"` setting is not
  `false`, it also turns PSI's `use_slacks` off on the build's copy of the network model.
- `DecisionModel{M}` takes `area_balance_slacks::Bool = true`, stored in the `"area_balance_slacks"` setting.
- Result key rename for NEM builds that use the AEMSim slack: `SystemBalanceSlackUp__Area` becomes
  `AreaBalanceSlack__Area__deficit`, and `SystemBalanceSlackDown__Area` becomes `AreaBalanceSlack__Area__surplus`.
  `read_constraint_violations` reports these under the `area_balance` family, with `up` for a deficit and `down` for a
  surplus.

## How

- Coefficient and bound parameters: a target stores `(constraint, variable, scale, param_row, multiplier_row,
  time_step)` (bound: `(constraint, active_lo, active_hi, ...)`). The per-step value update runs first, then all targets
  of the container are re-applied. A coefficient is set to `scale * value * multiplier`. A bound is set to
  `Interval(-Inf, Inf)` where `value * multiplier` is 0, else `Interval(lo, hi)`. Both throw on a rebuild model, a
  non-dense array or an out-of-range time step.
- Parameter containers for these types are stored as `Float64` in every build mode, through a more specific
  `_add_param_container!` method for `NEMFloatTimeSeriesParameter`. A coefficient or a row bound cannot be a JuMP
  parameter variable, since that would make the row quadratic.
- Update methods are defined for both `PSY.Component` and `PSY.Service` owners, for each new abstract type. Without the
  `Service` method, dispatch against PSI's `(ParameterType, U <: Service)` method is ambiguous. The generic-constraint
  update methods are concrete (see [0103](0103-aggregated-generic-constraint-containers.md)).
- The slack must be created at an argument stage, not later. PSI creates its own balance slacks inside
  `construct_network!` (build step 5), but the `ActivePowerBalance` expression keyed by `PSY.Area` exists from step 0
  and the balance constraint is built from it at step 5. A term added to the expression at an argument stage is
  therefore part of the balance row. The objective is materialised at step 8, so the cost can be added at the same stage.
- The gate: a template with no AEMSim formulation never calls `_add_area_balance_slacks!`, and keeps the caller's
  `use_slacks`. A template with such a formulation and an `AreaBalancePowerModel` network model replaces PSI's slacks,
  and a network model of another kind keeps its own slacks.

## Why

- The fork is reduced to general fixes that can be proposed upstream. AEMSim no longer depends on the fork's
  cost-, bound- and slack-specific API, so those fork commits can be dropped (see below).
- PSI's `slack_cost` is a flat constant (`1e6`) that the fork made configurable. AEMO prices the regional balance
  at CVP 150 and ranks it above the secure network limits (factor 30 to 35) and below FCAS max availability (155),
  so the balance needs its own price. Owning the slack keeps the price beside its CVP factor.

## Behaviour change from v0.2

- In v0.2 an `AreaBalancePowerModel` slack was priced at `AREA_BALANCE_CVP_FACTOR` times the Market Price Cap through
  the network model's `slack_cost`. Now a template of stock PSI formulations only (no AEMSim formulation), or a network
  model other than `AreaBalancePowerModel`, keeps PSI's own balance slacks at PSI's default cost (`1e6`), and so does a
  NEM template built with `area_balance_slacks = false`. This is a behaviour change for those builds.

## Remaining fork dependencies

AEMSim still needs the pinned PowerSimulations fork after this change, for:

- meta-keyed `add_parameters!(...; meta, time_series_name)` (used in `formulations/{fcas,tie_break,energy_offers,mnsp,fixed_loads,closed_loop,fast_start}.jl`);
- the registered-components-only `_update_parameter_values!` (fork `dd4e38d8`);
- the time-series cost and `MarketBidCost` commits;
- infinite `Interval` bound fixes (`8f20b08b`, `3d504be4`), since the invocation rows are `Interval(-Inf, Inf)`;
- the `/` escaping of store keys and the performance commits.

Fork commits droppable once this ADR is merged (rebase the later fork commits first):

- `b79d5dae` "Add ConstraintCoefficientParameter" and `547208ee` "Add ConstraintBoundParameter". The later cost-parameter
  commits (`86e93115`, `c2f76601`, `07045f5e`) reuse their `_time_series_parameter_eltype` hook and target-vector
  pattern, so they must carry the hook themselves.
- `8b78cce2` "Make the network balance slack penalty configurable" and `bcdb0c0f` "Require a positive network slack
  cost", with merges `9fdb8503` and `a6420984`.

## Market correctness

- The deficit and surplus slacks are CVP schedule v8.0 items 22 (`DeficitGen`, regional load shedding) and 23
  (`SurplusGen`, excess generation), both at 150. No departure from AEMO for the AEMSim slack.
- Coefficient and bound values are numerically unchanged. The balance dual is the marginal value of the balance row,
  which does not depend on the variable that relaxes it, so prices are unchanged where no slack is active.
- Stock-only templates are not NEM formulations; their slack cost is PSI's default, as described above.

## Known issue

PSI dual processing fails silently when the fixed-integer dual LP does not solve (pre-existing on v0.2, present in the
fork and in upstream PSI):

- When the fixed-integer dual LP returns `NO_SOLUTION`, `process_duals` returns early
  (`PowerSimulations/src/core/dual_processing.jl:93-100` in the pinned fork) without restoring binaries or variable
  bounds.
- `calculate_dual_variables!` discards the status. Every later step then solves as an LP, and the stored variables
  freeze at the failing step's values through `primal_values_cache`. Prices come from the corrupted LP's duals.
- Evidence: `/run/media/simba/Store/aem_validation/2026-11-19_compare_area-balance-slack-before_5399c14/` and
  `/run/media/simba/Store/aem_validation/2026-11-19_compare_area-balance-slack-v02base_5399c14/`.
- The 2025-01-14 before and after replay difference is incidental: both runs share this failure mode, so the
  difference between them does not measure this change.
- Root cause: the dual LP ran with the previous step's warm-start primal starts still set. HiGHS then skips
  presolve and its dual simplex aborts on the badly scaled objective ("excessive dual values"), which HiGHS.jl
  reports as `OTHER_ERROR`. Cold, the same LP solves in about 0.3 s. Evidence:
  `/run/media/simba/Store/aem_validation/2026-11-19_compare_dual-lp-failure_5399c14/` and the scaling audit in
  `/run/media/simba/Store/aem_validation/2026-11-20_compare_model-scaling-nempy_5399c14/` (nempy's cost ratio is the
  same; it solves its price LP cold).
- Resolved in the fork (ymiftah/PowerSimulations.jl#15, merged as `a92ab01f`): `process_duals` clears the primal starts
  for the dual LP, restores integer variables and starts on every exit, and a failed dual LP now fails the solve. The
  2025-01-14 replay from 04:05 then completes with price p99 error 1.0e-2 $/MWh against published, in
  `/run/media/simba/Store/aem_validation/2026-11-20_compare_dual-lp-starts-fix_5b31bc6/`.
