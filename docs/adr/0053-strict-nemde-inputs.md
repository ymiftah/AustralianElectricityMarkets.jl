# 0053 Historical dispatch requires complete inputs

## Status

Accepted. Run entry points named in the original decision were replaced by [0061](0061-problem-core-stock-simulation.md) and [0090](0090-template-is-the-problem-scope.md); the rule stands.

## What

- Run fails before the build, with a named `ArgumentError`, when an input it depends on is missing or only partly usable. A completed solve is not evidence of a complete reconstruction when a missing input silently selects another formulation (a missing Basslink offer once produced a free-flowing interconnector and the largest Tasmania price error).
- The fix for an error is to supply the data or implement the equation, never to relax the check.

## How

- MNSP (`set_mnsp_offers!`): status comes from effective-dated `INTERCONNECTORCONSTRAINT.ICTYPE`, not from whether offer rows exist. An MNSP needs two registered directional links with compatible endpoints, terminal factors (`LHSFACTOR`), exactly one offer per interval and finite metered flow.
- Energy bids (`_check_nemde_energy_bid_coverage`, called by `nem_system` with `NEMDEConfiguration`): every scheduled unit that is available or metered needs an energy offer for every registered interval and direction with a valid `MAXAVAIL`, and every region with a unit needs regional demand for every interval. Non-scheduled units and units not in the system are not validated. A wholesale demand response unit bids `GEN` only.
- Constraints and dispatch limits (`check_template_against_sys`, `_check_nemde_system_inputs`): throws on missing `DISPATCHCONSTRAINT` intervals, constraints with a NULL weight (default penalty), skipped constraint definitions, dropped unit terms of registered units, and devices with no dispatch-limit series.
- Participant fixed loadings come from `FIXEDLOAD` inputs, penalised at `FIXED_LOADING_CVP_FACTOR` (380).

## Why

- Sources: AEMO Electricity Data Model Report v5.7.0 (`INTERCONNECTORCONSTRAINT.ICTYPE`, `MNSP_INTERCONNECTOR`, `MNSP_DAYOFFER`, `MNSP_BIDOFFERPERIOD`, `DISPATCH_MNSPBIDTRK`); AEMO Schedule of Constraint Violation Penalty Factors v8.0, item 13 (participant fixed loading, unit equality, factor 380).
- Reader tests keep deliberately invalid constraints; run fixtures must use complete inputs.
