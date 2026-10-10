# Phase 2.7: elastic generic constraints (constraint-violation slack + pricing)

Status: implemented 2026-09-30, corrected 2026-09-30 after review. Plan:
`~/.claude/plans/nem-redesign-phase2.md` 2.7. Base: `pr-2.9-fcas-joint-ramping` at `105c6ae`.

## Goal

`LinearFactorLimit` builds every `GenericConstraint` as a hard bound. A real dispatch interval
whose requirement genuinely wasn't met makes the LP infeasible the moment it is replayed. This PR
adds elastic slack variables, priced at AEMO's own constraint-violation rate, so a genuinely
violated interval builds and solves with a nonzero slack instead of throwing or failing to solve.
2.8 (FCAS joint requirement rows) reuses the same mechanism, so the slack construction is written
once, keyed only off `get_sense(gc)`.

## AEMO sources

- nem-expert `references/data-model/GENCONDATA.md` (line 41): `GENERICCONSTRAINTWEIGHT` is "The
  constraint violation penalty factor", not merely a priority weight.
- *Schedule of Constraint Violation Penalty Factors* (v8.0), section 1: `cost = CVP factor x
  Market Price Cap x Violation degree`.
- Verified directly against cached `DISPATCHCONSTRAINT`/`GENCONDATA` rows, May-August 2026: every
  violated row (`VIOLATIONDEGREE > 0`, `INTERVENTION = 0`) with a version-matched `GENCONDATA` row
  has `|MARGINALVALUE| = GENERICCONSTRAINTWEIGHT x Market Price Cap` exactly (weight 35 against
  the FY25-26 MPC of $20,300 gives $710,500; weight 360 against the FY26-27 MPC of $23,200 gives
  $8,352,000).
- nem-expert `references/reliability-settings/00-purpose-and-values.md`: Market Price Cap $20,300
  from 1 July 2025, $23,200 from 1 July 2026. `MARKET_PRICE_THRESHOLDS.VOLL` is not cached by this
  codebase, so these values are typed into `MARKET_PRICE_CAP_BY_FINANCIAL_YEAR` from the AEMC
  schedule text.
- `AustralianElectricityMarketsSimulations/src/time_basis.jl`'s `interval_cost_coefficient` and
  `fcas_market.jl`'s own use of it (`$/MWh` to a `$/MW`-per-interval objective coefficient, scaled
  by `PSI.get_base_power(container)`) set the unit convention every other price in this package's
  objective already follows.

## nempy cross-check

`nempy.historical_inputs.constraint_data.ConstraintData.get_violation_costs` reads a per-`set`
dollar cost straight from the NEMDE XML case file for the interval being replayed (values like
$6,300,000 for a network constraint, $525,000 for others), not derived from
`GENERICCONSTRAINTWEIGHT` or a Market Price Cap, because nempy has the real per-constraint price
available from AEMO's own solver input. This codebase caches MMSDM only, not NEMDE XML, so it
cannot read that price directly; `GENERICCONSTRAINTWEIGHT x Market Price Cap` reproduces the same
number from cached data, confirmed exactly against real violated rows above.

## Design

### Variable types (`AustralianElectricityMarketsSimulations/src/constraint_formulations.jl`)

- `GenericConstraintSlackUp <: PSI.VariableType`: absorbs LHS above RHS (`LE`/`EQ` senses).
- `GenericConstraintSlackDown <: PSI.VariableType`: absorbs LHS below RHS (`GE`/`EQ` senses).

Only the side(s) `get_sense(gc)` needs are built, gated on `PSI.ServiceModel`'s existing
`use_slacks::Bool` field (the same field PSI's own `transmission_interface_slacks!` gates on for
`PSY.TransmissionInterface`). No new field on `LinearFactorLimit` itself.

### Mechanism (`AustralianElectricityMarketsSimulations/src/nem_constraints.jl`)

- `_add_gc_slack_variables!(container, gc, model)`: a no-op unless `PSI.get_use_slacks(model)`.
  Builds the needed slack(s) as one `JuMP.@variable` per `(name, t)` with `lower_bound = 0.0`, and
  merges each into `NEMConstraintLHS`: `-slack_up` on the `LE`/`EQ` side, `+slack_down` on the
  `GE`/`EQ` side. Called from `construct_service!`'s `ModelConstructStage` after the terms loop
  and before `PSI.add_constraints!`, so the stored `NEMConstraintLimit` constraint is built already
  relaxed.
- `MARKET_PRICE_CAP_BY_FINANCIAL_YEAR`: a `Date => $/MWh` table, keyed by financial-year start (1
  July). `_financial_year_mpc(t)` finds the entry covering `t`, throwing if none does.
- `_market_price_cap(model, t)`: the `"market_price_cap"` `PSI.ServiceModel` attribute if set,
  otherwise `_financial_year_mpc(t)`.
- `PSI.objective_function!(container, gc, model::ServiceModel{GenericConstraint,
  LinearFactorLimit})`: reads back whichever slack container(s) `_add_gc_slack_variables!` built
  and adds, per `(name, t)`, `slack[t] * base_power * interval_cost_coefficient(weight * mpc,
  resolution)` via `PSI.add_to_objective_invariant_expression!`, where `weight =
  get_constraint_weight(gc)` and `mpc = _market_price_cap(model, timestamp_of(t))`.

## Departures from the plan

- The plan's "a documented, cited field on the formulation struct, supplied by the caller" is
  realised as a `PSI.ServiceModel` attribute (`"market_price_cap"`), not a field on
  `LinearFactorLimit` itself, because every existing call site passes `LinearFactorLimit` as a
  bare type parameter (`ServiceModel{T, D}` dispatches on `D` as a type), not an instance.
- No `NEMDispatchPolicy` type (already dropped by the plan itself).
- `MARKET_PRICE_CAP_BY_FINANCIAL_YEAR` only covers FY25-26 and FY26-27, the years the cited AEMC
  schedule publishes; a replay outside that range throws rather than guessing a rate.
- Pricing PSI's own area-balance slack at its correct CVP rate (factor 150) is deferred to 2.8,
  recorded in the Phase 2 plan file, not fixed here.

## Tests

`test/nem_constraints.jl`: a `>=` `GenericConstraint` (`N_INFEASIBLE_MIN`) requires "Park City" to
dispatch at ten times its max capacity, genuinely unreachable. The hard `LinearFactorLimit`
template (same `_area_balance_template()` network config as the elastic case, only
`use_slacks` differs) builds but fails to solve; the elastic one builds, solves, and: the slack
plus the unit's achieved dispatch equals the RHS exactly (the GE constraint binds under a
minimized slack), the objective is strictly positive, and the constraint's dual magnitude equals
`weight * MPC` over the interval. `test/real_data/runtests.jl` adds an elastic-slack report
against cached `DISPATCHCONSTRAINT.VIOLATIONDEGREE` for the real window it already builds.
`constraint_formulations.jl` gets a type-hierarchy check for the two new `VariableType`s.

## Files

- `AustralianElectricityMarketsSimulations/src/constraint_formulations.jl`: slack `VariableType`s.
- `AustralianElectricityMarketsSimulations/src/nem_constraints.jl`: slack construction, MPC table
  and lookup, `objective_function!`.
- `AustralianElectricityMarketsSimulations/src/AustralianElectricityMarketsSimulations.jl`: exports.
- `AustralianElectricityMarketsSimulations/test/nem_constraints.jl`,
  `test/constraint_formulations.jl`, `test/real_data/runtests.jl`: tests.
- `docs/adr/0021-elastic-generic-constraints.md`: this design's rationale record.
