# 0067 Participant fixed loading is unit offer data

## Status

Accepted. The offer views and series naming of the original decision are superseded by [0093](0093-nem-device-types-and-offer-cost.md) and [0099](0099-one-series-per-bid-input.md); only the fixed-loading and FCAS band decisions below remain.

## What

- A participant fixed loading (AEMO's Energy Inflexible Offer, *Schedule of Constraint Violation Penalty Factors* v8.0 item 13, "Unit = X MW", CVP 380) is unit offer data, not a generic constraint. Rows flagged `IN_PROFILE` are excluded.
- `set_nem_fixed_loads!` attaches `"fixed_load"` (net target, system-base per-unit) and `"fixed_load_invoked"` to each unit that has one. A storage device's `GEN` and `LOAD` loadings net into one target, `GEN - LOAD`.
- FCAS offer curves keep all ten bands (`FCAS_BAND_COUNT`), so band `k` is AEMO price band `k`, as for energy offers.

## How

- `AbstractNEMDispatch` holds the unit's net energy at the target with two `NEMUnitConstraint` rows (metas `fixed_load|upper`, `fixed_load|lower`), elastic through `NEMUnitSlack` variants `fixed_load|surplus` and `fixed_load|deficit` priced at `FIXED_LOADING_CVP_FACTOR` (380) times the Market Price Cap. At an uninvoked interval both rows are relaxed by a large constant. Violations report under family `fixed_load`.
- The rows are unit rows: they are not counted among generic constraints or their duals.

## Why

- NEMDE nets a bidirectional unit's loadings the same way: in the 2025-03-04 case files (`NemSpdOutputs_20250304_loaded.zip`) `$ERB01` is one `EQ` constraint with a single `TradeType="BDOF"` trader factor, with solved RHS `-2` for a 2 MW `LOAD` loading at 11:00 and `3` for a 3 MW `GEN` one at 11:15. `BDOF` first appears in the trading day of 2024-07-03 (BHB1, WANDB1); before that a battery's load side is a separate DUID with `LDOF` terms, so its loadings are already per device. nempy (commit `2d3cef0`) nets every unit-level energy term of a bidirectional unit but has no fixed-loading logic of its own, so it is no independent evidence.
- A constraint-per-DUID encoding forced a special-cased CVP lookup and counted unit rows as generic constraints.
