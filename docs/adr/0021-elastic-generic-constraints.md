# 0021 Elastic `GenericConstraint`s priced at CVP factor times Market Price Cap

## Status

Accepted. The cap lookup and its override are now as in [0085](0085-build-time-market-price-cap.md); the other elastic families follow the same pricing ([0023](0023-elastic-fcas-rows-and-area-balance-cvp.md), [0030](0030-elastic-unit-ramp-rows.md)).

## What

- With `use_slacks = true` on the `LinearFactorLimit` `PSI.ServiceModel`, a `GenericConstraint` is soft: violating it costs `CVP factor x Market Price Cap x violation` (AEMO *Schedule of Constraint Violation Penalty Factors* v8.0, section 1).
- The CVP factor is `GENCONDATA.GENERICCONSTRAINTWEIGHT` verbatim (`constraint_cvp_factor`); the base rate is the Market Price Cap of the financial year (1 July to 30 June), not a flat dollar rate. A `NULL` weight is read as 1.0 (`nem_system` warns).
- With `use_slacks = false` (the PSI default) the row is a hard bound with no slack and no cost.

## How

- `GenericConstraintSlackUp` / `GenericConstraintSlackDown` (`PSI.VariableType`) are built by `_add_gc_slack_variables!` for the side(s) the sense needs (`LE` up, `GE` down, `EQ` both) and merged into `NEMConstraintLHS` (`-up`, `+down`).
- `PSI.objective_function!` for `ServiceModel{GenericConstraint, LinearFactorLimit}` adds `slack * base_power * interval_cost_coefficient(weight, resolution) * mpc` to the invariant objective, with `mpc` from `_container_market_price_cap` at the build's initial time.
- `MARKET_PRICE_CAP_BY_FINANCIAL_YEAR` is the published cap per financial year (AEMC schedules). `_financial_year_mpc` needs an exact year entry and throws otherwise; extend the table by hand each year, or set the `"market_price_cap"` entry of the model settings.

## Why

- `GENERICCONSTRAINTWEIGHT` is documented as the CVP factor, and every violated `DISPATCHCONSTRAINT` row checked (May to August 2026, `INTERVENTION = 0`) had `|MARGINALVALUE| = weight x Market Price Cap`. A flat rate (for example nempy's `ViolationPrice`) is an older NEMDE-internal base and is wrong.
- Hard rows turn real data whose requirement genuinely was not met into an infeasible LP; NEMDE prices the violation instead.
- Slack costs carry `base_power` and `interval_cost_coefficient`, as every other objective term does, so a per-unit slack is priced per MW of one interval.
