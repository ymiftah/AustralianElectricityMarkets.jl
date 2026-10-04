# 0021. Elastic `GenericConstraint`s: Market Price Cap by financial year, `PSI.ServiceModel`-attribute override

## Status

Accepted

## Context

`LinearFactorLimit` built every `GenericConstraint` as a hard bound (`NEMConstraintLimit`). A real
dispatch interval whose requirement genuinely wasn't met makes that LP infeasible the instant it is
replayed. The Phase 2 plan (2.7) decided pricing is mandatory for v0.2: hard infeasibility on
ordinary real data is not acceptable, and the salvage branches' `objective_function!` no-op stub
must not be ported as-is.

Three design points needed a decision.

### What is the CVP rate, and where does it come from?

`GENCONDATA.GENERICCONSTRAINTWEIGHT` is documented as "The constraint violation penalty factor"
(nem-expert `references/data-model/GENCONDATA.md`). AEMO's *Schedule of Constraint Violation
Penalty Factors* (v8.0, section 1) gives the formula `cost = CVP factor x Market Price Cap x
Violation degree`. Checked against cached `DISPATCHCONSTRAINT`/`GENCONDATA` rows for May-August
2026: every violated row (`VIOLATIONDEGREE > 0`, `INTERVENTION = 0`) with a version-matched
`GENCONDATA` row has `|MARGINALVALUE| = GENERICCONSTRAINTWEIGHT x Market Price Cap` exactly (for
example weight 35 against the FY25-26 MPC of $20,300 gives $710,500; weight 360 against the
FY26-27 MPC of $23,200 gives $8,352,000). An earlier draft of this ADR used a single constant,
$140,000/MW, derived from `nempy`'s NEMDE-XML `ViolationPrice` for one FCAS item (CVP factor 8 x
$17,500, an older NEMDE-internal base rate) misread as an observed dollar rate; it is wrong and is
replaced here.

**Decided:** the base rate is the Market Price Cap for the interval's financial year (1 July to 30
June), and `GENERICCONSTRAINTWEIGHT` is the CVP factor, verbatim, not merely "a" weight.
`MARKET_PRICE_CAP_BY_FINANCIAL_YEAR` holds the published values from nem-expert
`references/reliability-settings/00-purpose-and-values.md`: $20,300/MWh from 1 July 2025, $23,200
from 1 July 2026. `MARKET_PRICE_THRESHOLDS.VOLL` is not cached by this codebase, so this table is
sourced from AEMC's schedule text, not read from the cache; it needs extending by hand when a new
financial year's MPC is published, or when a replay reaches back before FY25-26.

### Where does the rate live: a formulation struct field, or a `PSI.ServiceModel` attribute?

`LinearFactorLimit` is a singleton struct used only as a bare type parameter,
`PSI.ServiceModel(GenericConstraint, LinearFactorLimit; ...)`, at every existing call site. PSI's
own `ServiceModel{T, D}` dispatches on `D` as a type, never an instance, so a struct field on
`LinearFactorLimit` has no way to reach the code that would read it.

**Decided:** an optional override lives in `PSI.ServiceModel`'s own `attributes::Dict{String,
Any}` field, under the key `"market_price_cap"`, read by `_market_price_cap`. Absent an override,
the rate comes from `_financial_year_mpc`, keyed off the interval's own timestamp. `use_slacks`
is `PSI.ServiceModel`'s own existing field, the same one PSI's own `transmission_interface_slacks!`
gates on for `PSY.TransmissionInterface`.

### Objective units

Every other cost this package adds to the PSI objective goes through
`interval_cost_coefficient(price, resolution)` (`$/MWh` to `$/MW` over one interval) and a
`base_power` scale from per-unit to MW, matching how `fcas_market.jl` prices an offer band. The
first version of this change added `slack_pu * rate` directly, omitting both factors, so a
$1/pu-slack cost in the model corresponded to `base_power` MW priced at one dispatch interval's
worth of `$/MWh`, not`$/MW` for the interval. Corrected: `slack_pu *base_power*
interval_cost_coefficient(weight * mpc, resolution)`.

## Decision

- `GenericConstraintSlackUp`/`GenericConstraintSlackDown <: PSI.VariableType`
  (`AustralianElectricityMarketsSimulations/src/constraint_formulations.jl`): built only for the
  side(s) `get_sense(gc)` needs (`LE` gets up, `GE` gets down, `EQ` gets both), and only when
  `PSI.get_use_slacks(model)`.
- `_add_gc_slack_variables!` creates them and merges each into `NEMConstraintLHS` (`-slack_up`,
  `+slack_down`) before `PSI.add_constraints!` runs.
- `PSI.objective_function!(container, gc, ServiceModel{GenericConstraint, LinearFactorLimit})`
  prices each built slack at `slack[t] * base_power * interval_cost_coefficient(weight * mpc,
  resolution)`, `mpc` from `_market_price_cap(model, timestamp)`. A `GenericConstraint` built
  without slacks still carries no cost of its own.

## Consequences

- A `LinearFactorLimit` `PSI.ServiceModel` with `use_slacks = false` (the PSI default) behaves
  exactly as before this change: hard bound, no slack, no cost.
- Elasticity is opt-in per `PSI.ServiceModel` registration.
- `MARKET_PRICE_CAP_BY_FINANCIAL_YEAR` needs a manual entry added for each future financial year;
  a replay whose interval falls outside the table throws rather than silently pricing at the wrong
  rate.
- A `GenericConstraint` with a `NULL` `GENERICCONSTRAINTWEIGHT` (coalesced to `1.0` in
  `src/constraints/build.jl`) or no version-matched `GENCONDATA` row prices its slack at `1 x MPC`
  rather than its true CVP rate; the cache holds violated `GENCONID`s with no matching `GENCONDATA`
  row (for example `N_PARSF1_4INV`, `N_STUBSF_76INV`). This is unchanged from before this PR and is
  a pre-flight-check candidate, not fixed here.
- 2.8 (elastic FCAS joint requirement rows) reuses `_add_gc_slack_variables!`'s sense-keyed
  construction and the same priced-objective mechanism unchanged.
- PSI's own area-balance slack (`use_slacks = true` on the `AreaBalancePowerModel` network model)
  is priced by PSI at a fixed `BALANCE_SLACK_COST` (about $12,000/MWh equivalent, pinned PSI
  `core/definitions.jl`), independent of this PR's corrected GenericConstraint slack pricing. At
  the corrected rate a Secure Network Limit Thermal-class constraint (CVP factor 30-35) now prices
  above the area-balance slack, while AEMO's own CVP ranking puts the area balance (factor 150,
  nem-expert `constraint-violation-penalty-factors/05-items-22-35.md`) above it. Reconciling the
  two slack costs is recorded as a Phase 2 follow-up (2.8) in the plan file; resolved in ADR 0022.

## Review follow-up, 2026-10-01

The financial-year lookup now requires an exact year entry, including for dates after the last
published year. The earlier lower-bound lookup silently reused FY2026-27's price for FY2027-28
and later, contradicting the intended failure on unknown years.

The 2026-06-09 real-data comparison uses each constraint's `invoked` time series to select the
model intervals where that constraint is active. PSI still returns results for the full model
window, including uninvoked intervals; those intervals must have zero slack and are excluded from
the published violation and dual comparisons. Every invoked model timestamp must have a published
`DISPATCHCONSTRAINT` row, so missing coverage cannot disappear through an inner join. The mask's
length and timestamps are checked against both result tables. Slack equality uses a per-row MW
tolerance, and CVP dual equality is asserted only where the published violation is positive. At
zero violation the dual is not uniquely fixed by the slack penalty. The pre-fix real-data run had
13 passing assertions and two failures caused by joining uninvoked intervals. The focused
post-fix real-data test passed all 31 assertions on 2026-10-01, including invoked coverage,
zero slack outside invocation, and the published slack and dual comparisons.
