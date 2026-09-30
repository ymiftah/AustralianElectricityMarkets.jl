# Phase 2.7: elastic generic constraints (constraint-violation slack + pricing)

Status: implemented 2026-09-30. Plan: `~/.claude/plans/nem-redesign-phase2.md` §2.7.
Base: `pr-2.9-fcas-joint-ramping` at `105c6ae`.

## Goal

`LinearFactorLimit` currently builds every `GenericConstraint` as a hard bound. A real dispatch
interval whose requirement genuinely wasn't met (AEMO's own TAS1 `RAISE6SEC` example, where
`DISPATCHCONSTRAINT.MARGINALVALUE = 140,000` — a CVP price, not a market price) makes the LP
infeasible the moment it is replayed. This PR adds elastic slack variables, priced at a
constraint-violation rate, so a genuinely violated interval builds and solves with a nonzero
slack instead of throwing or failing to solve. §2.8 (FCAS joint requirement rows) reuses the same
mechanism, so the slack construction is written once, keyed only off `get_sense(gc)`.

## AEMO sources

- *Schedule of Constraint Violation Penalty Factors* (v8.0, effective 2025-12-02), §1
  (Introduction): NEMDE prices a violation as `CVP factor × Market Price Cap × Violation degree`,
  where `CVP factor = CVP price / MPC` is a dimensionless, per-constraint-**type** multiplier.
  §3 Table 1 lists the CVP factor for each of 53 constraint types by name (e.g. Item 30, "Secure
  Network Limit Thermal constraint... ": CVP factor 30; Item 41, "FCAS R6 Requirement
  constraint": CVP factor 8) — never a dollar figure, and never keyed by `GENCONID`.
- `nem-expert` `references/data-model/GENCONDATA.md` / `DISPATCHCONSTRAINT.md`:
  `GENERICCONSTRAINTWEIGHT` (`GENCONDATA`) is a dimensionless per-constraint weight, unrelated to
  the CVP factor above; `VIOLATIONDEGREE`/`MARGINALVALUE` (`DISPATCHCONSTRAINT`) are NEMDE's
  *outputs* for a solved interval, not inputs.
- The repo's own real-data evidence (cited in the Phase 2 plan): a cached TAS1 `RAISE6SEC`
  interval where `MARGINALVALUE = 140,000` — an actually-observed CVP-priced dollar rate.

**Gap this PR does not close.** The dollar CVP price NEMDE applies per constraint is carried in
AEMO's NEMDE XML solver inputs (see `nempy`'s `ConstraintData.get_violation_costs`, which reads
per-`GENCONID` dollar values like `6,300,000` or `525,000` directly from that XML), not in any
MMSDM table this codebase caches. Classifying every `GENCONID` against Table 1's 53 constraint
types from `GENCONDATA` alone is not attempted here — `GENCONDATA` carries no constraint-type
column that maps onto Table 1's categories. This PR uses one caller-supplied `$/MW` rate for
every `GenericConstraint`, scaled by the constraint's own `GENERICCONSTRAINTWEIGHT`, and records
the departure below.

## nempy cross-check

`nempy.historical_inputs.constraint_data.ConstraintData.get_violation_costs` reads a per-`set`
(constraint) dollar cost straight from the NEMDE XML case file for the interval being replayed,
then `SpotMarket.make_constraints_elastic('generic', violation_costs)` adds one slack per
constraint row, priced at that exact dollar figure — nempy never derives a price from
`GENERICCONSTRAINTWEIGHT` or the CVP Factors schedule, because it has the real per-constraint
price available. That data source isn't part of this package's Phase 1 scope (MMSDM only, no
NEMDE XML client), so this PR's caller-supplied rate × `GENERICCONSTRAINTWEIGHT` is a deliberate,
documented approximation where nempy has an exact answer.

## Design

### Variable types (`…Simulations/src/constraint_formulations.jl`)

- `GenericConstraintSlackUp <: PSI.VariableType` — absorbs LHS above RHS (`LE`/`EQ` senses).
- `GenericConstraintSlackDown <: PSI.VariableType` — absorbs LHS below RHS (`GE`/`EQ` senses).

Only the side(s) `get_sense(gc)` needs are built, matching the plan and
`PSI.ServiceModel`'s existing `use_slacks::Bool` field (the same field
`transmission_interface_slacks!` gates on for `PSY.TransmissionInterface`) — no new field on
`LinearFactorLimit` itself; it stays a singleton `AbstractNEMConstraintFormulation` subtype and
takes its policy from the `PSI.ServiceModel` instance, exactly like every other formulation
attribute in this codebase.

### Mechanism (`…Simulations/src/nem_constraints.jl`)

- `_add_gc_slack_variables!(container, gc, model)`: a no-op unless
  `PSI.get_use_slacks(model)`. Builds the needed slack(s) as one `JuMP.@variable` per
  `(name, t)` with `lower_bound = 0.0`, and merges each into `NEMConstraintLHS` — `-slack_up` on
  the `LE`/`EQ` side, `+slack_down` on the `GE`/`EQ` side — mirroring
  `InterfaceFlowSlackUp`/`InterfaceFlowSlackDown`'s merge into `InterfaceTotalFlow` in installed
  PSI's `TransmissionInterface`. Called from `construct_service!`'s `ModelConstructStage` after
  the terms loop and before `PSI.add_constraints!`, so the stored `NEMConstraintLimit` constraint
  is built already relaxed, not tightened first and loosened after.
- `PSI.objective_function!(container, gc, model::ServiceModel{GenericConstraint,
  LinearFactorLimit})`: previously an unconditional no-op (the salvage branches' stub the plan
  says not to port). Now reads back whichever slack container(s) `_add_gc_slack_variables!` built
  (`PSI.has_container_key`) and adds `slack[t] * rate` to the objective via
  `PSI.add_to_objective_invariant_expression!`, where
  `rate = gc.constraint_weight * base_cvp_rate`.
- `base_cvp_rate` is the `"base_cvp_rate"` string key of the `PSI.ServiceModel`'s own
  `attributes::Dict{String, Any}` (`PSI.get_attribute(model, "base_cvp_rate")`), defaulting to
  `DEFAULT_GENERIC_CONSTRAINT_CVP_RATE = 140_000.0` (the TAS1 `RAISE6SEC` observation above) when
  unset. A caller sets a different rate via
  `PSI.ServiceModel(GenericConstraint, LinearFactorLimit; attributes = Dict("base_cvp_rate" =>
  ...), use_slacks = true)` — this is the "documented, cited field... supplied by the caller" the
  plan calls for, expressed through PSI's own attribute mechanism rather than a new struct field,
  since `LinearFactorLimit` is dispatched as a bare type parameter (`ServiceModel{T, D}`) in every
  call site already in this codebase (`test/nem_constraints.jl`, `test/toy_fixture.jl`,
  `test/real_data/runtests.jl`), not instantiated.

### Departures from the plan

- The plan's own phrasing, "a documented, cited field on the formulation struct", is realised as
  a `PSI.ServiceModel` attribute rather than a field on `LinearFactorLimit` itself, because every
  existing call site passes `LinearFactorLimit` as a type, not a value — adding a field would
  need a constructor and break every one of those call sites for no behavioural gain `ServiceModel`
  attributes don't already provide.
- No `NEMDispatchPolicy` type (already dropped by the plan itself).

## Tests

`…Simulations/test/nem_constraints.jl`: a new `@testset` adds a `>=` `GenericConstraint`
(`N_INFEASIBLE_MIN`) requiring "Park City" to dispatch at ten times its max capacity — genuinely
unreachable, not merely tightened-but-satisfiable — and shows the hard `LinearFactorLimit`
template builds but fails to solve, while the same system under `use_slacks = true` builds,
solves successfully, and reports a strictly positive `GenericConstraintSlackDown` value (read via
`PSI.OptimizationProblemResults`/`PSI.read_variable`, the same API the file's other solved-model
tests already use for variable values) and a strictly positive objective. `constraint_formulations.jl`
gets a type-hierarchy check for the two new `VariableType`s.

## Files

- `…Simulations/src/constraint_formulations.jl` — `GenericConstraintSlackUp`/`SlackDown` types.
- `…Simulations/src/nem_constraints.jl` — `_add_gc_slack_variables!`,
  `DEFAULT_GENERIC_CONSTRAINT_CVP_RATE`, `_base_cvp_rate`, real `objective_function!`.
- `…Simulations/src/AustralianElectricityMarketsSimulations.jl` — exports.
- `…Simulations/test/nem_constraints.jl`, `test/constraint_formulations.jl` — tests.
- `docs/adr/0021-elastic-generic-constraints.md` — this design's rationale record.
