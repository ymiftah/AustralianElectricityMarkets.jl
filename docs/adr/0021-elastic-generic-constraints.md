# 0021. Elastic `GenericConstraint`s: `PSI.ServiceModel`-attribute pricing, not a formulation field

## Status

Accepted

## Context

`LinearFactorLimit` built every `GenericConstraint` as a hard bound (`NEMConstraintLimit`). A real
dispatch interval whose requirement genuinely wasn't met — AEMO's own published example, TAS1's
`RAISE6SEC` at a `DISPATCHCONSTRAINT.MARGINALVALUE` of \$140,000, a constraint-violation price, not
a market price — makes that LP infeasible the instant it is replayed. The Phase 2 plan (§2.7)
decided pricing is mandatory for v0.2: hard infeasibility on ordinary real data is not acceptable,
and the salvage branches' `objective_function!` no-op stub must not be ported as-is.

Two design points needed a decision.

### Where does the CVP dollar rate come from?

AEMO's *Schedule of Constraint Violation Penalty Factors* (v8.0, §1) prices a violation as
`CVP factor × Market Price Cap × Violation degree`, where the CVP factor is a dimensionless,
per-constraint-**type** multiplier (§3 Table 1 lists 53 types, e.g. Item 30 "Secure Network Limit
Thermal constraint...": 30; Item 41 "FCAS R6 Requirement constraint": 8). The actual dollar figure
NEMDE applies to a specific `GENCONID` at a specific interval is carried in AEMO's NEMDE XML solver
inputs — confirmed by `nempy`'s `ConstraintData.get_violation_costs`, which reads exact per-`set`
dollar values (\$6,300,000, \$525,000, etc.) straight from that XML — not in any MMSDM table this
codebase caches. `GENCONDATA` carries a `GENERICCONSTRAINTWEIGHT` column, but it is a distinct,
dimensionless per-constraint weight unrelated to the CVP factor, and `GENCONDATA` has no column
mapping a `GENCONID` onto one of Table 1's 53 constraint-type categories.

Building that classification (parsing `DESCRIPTION`/`LIMITTYPE` text heuristically against Table
1's categories) was rejected as unreliable and out of scope for this PR — it would be guessing at
a mapping AEMO does not publish in MMSDM. **Decided:** use one caller-supplied `$/MW` rate for
every `GenericConstraint`, scaled by its own `GENERICCONSTRAINTWEIGHT` (already available, already
meaningful as a per-constraint relative-priority signal even though it is not the CVP factor). The
default rate, `DEFAULT_GENERIC_CONSTRAINT_CVP_RATE = 140_000.0`, is the one dollar figure actually
observed in cached NEMWEB data (the TAS1 `RAISE6SEC` example above), not derived from Table 1 —
recorded here as a known simplification, not a discovered AEMO constant. A per-`GENCONID`,
per-interval dollar table is a Phase 3 option (mirrors the plan's own "dated rate table" deferral)
if multi-year replay pricing needs it.

### Where does the rate live: a formulation struct field, or a `PSI.ServiceModel` attribute?

The plan's own text asked for "a documented, cited field on the formulation struct, supplied by
the caller". `LinearFactorLimit` is a singleton struct used only as a bare type parameter —
`PSI.ServiceModel(GenericConstraint, LinearFactorLimit; ...)` — at every existing call site
(`test/nem_constraints.jl`, `test/toy_fixture.jl`, `test/real_data/runtests.jl`); PSI's own
`ServiceModel{T, D}` dispatches on `D` as a type, never an instance, so a struct field on
`LinearFactorLimit` has no way to reach the code that would read it without either instantiating
`D` (a change PSI's own machinery doesn't expect) or adding a second, parallel path.

**Decided:** use `PSI.ServiceModel`'s own `attributes::Dict{String, Any}` field instead — the same
mechanism `PSI.get_default_attributes(::Type{GenericConstraint}, ::Type{LinearFactorLimit})`
already establishes for this exact `(T, D)` pair, and the same shape PSI's own `TransmissionInterface`
formulations use for their per-model configuration. A caller sets
`PSI.ServiceModel(GenericConstraint, LinearFactorLimit; attributes = Dict("base_cvp_rate" => ...),
use_slacks = true)`; `_base_cvp_rate(model)` reads it back, falling to the module constant when
unset. `use_slacks::Bool` is `PSI.ServiceModel`'s own existing field — the same one
`transmission_interface_slacks!` gates on for `PSY.TransmissionInterface` in installed PSI — so no
new boolean was introduced either.

## Decision

- `GenericConstraintSlackUp`/`GenericConstraintSlackDown <: PSI.VariableType`
  (`…Simulations/src/constraint_formulations.jl`): built only for the side(s) `get_sense(gc)`
  needs (`LE` → up, `GE` → down, `EQ` → both), and only when `PSI.get_use_slacks(model)`.
- `_add_gc_slack_variables!` (`…Simulations/src/nem_constraints.jl`) creates them and merges each
  into `NEMConstraintLHS` (`-slack_up`, `+slack_down`) before `PSI.add_constraints!` runs, mirroring
  `InterfaceFlowSlackUp/Down`'s merge into `InterfaceTotalFlow` in installed PSI.
- `PSI.objective_function!(container, gc, ServiceModel{GenericConstraint, LinearFactorLimit})` is no
  longer an unconditional no-op: it reads back whichever slack container(s) exist and adds
  `slack[t] * (gc.constraint_weight * base_cvp_rate)` via `PSI.add_to_objective_invariant_expression!`.
  A `GenericConstraint` built without slacks still carries no cost of its own.

## Consequences

- A `LinearFactorLimit` `PSI.ServiceModel` with `use_slacks = false` (the PSI default) behaves
  exactly as before this PR: hard bound, no slack, no cost.
- Elasticity is opt-in per `PSI.ServiceModel` registration, matching how `filter_buildable_generic_constraints`
  callers already choose per-instance vs. aggregated registration.
- `GENERICCONSTRAINTWEIGHT` now has two roles in this codebase: its original use (verbatim,
  read-only field on `GenericConstraint`) and, when slacks are enabled, a multiplier on the
  elastic-violation cost. Both are the same AEMO column; nothing new is invented on top of it.
- §2.8 (elastic FCAS joint requirement rows) reuses `_add_gc_slack_variables!`'s
  sense-keyed construction unchanged.
