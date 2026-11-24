# 0094 HiGHS root heuristics off; tied optima are not resolved by solver options

## Status

Accepted

## What

- `NEMDE_HIGHS_OPTIONS` (`AustralianElectricityMarketsSimulations/src/problems/optimizer.jl`) sets the MIP gaps to `1e-9` relative and `1e-10` absolute and turns off four HiGHS root sub-MIP heuristics: `mip_heuristic_run_rins`, `mip_heuristic_run_rens`, `mip_heuristic_run_root_reduced_cost` and `mip_heuristic_run_feasibility_jump`. `nemde_optimizer(; attributes...)` applies them, and keyword attributes override.
- The run MILP has many tied optima: different primal solutions at the same objective. Solver options change which one HiGHS returns, so prices (duals of the fixed LP), flows and FCAS prices can differ at equal objectives, and so can their match to AEMO's published outcome. NEMDE resolves ties by its own rules, which the run does not model.

## Why

- Speed: on 2026-06-04 (288 intervals, one HiGHS thread) the all-off setting summed 635 s with a 9.6 s slowest interval. HiGHS defaults summed 1301 s with a 91.9 s slowest interval and fit AEMO slightly better (energy price MAE 0.0328 against 0.0380 $/MWh, FCAS 0.0006 against 0.0016).
- Only RENS accounts for the fit difference, at about 120 s per day and 8 s on the slowest interval. It was not adopted; the measurement covers one day only.
- Relative gap `1e-9`, not `1e-8`: on a 1e7 objective `1e-8` lets HiGHS stop about 0.1 above optimal with an interconnector on a loss breakpoint, where the fixed-indicator dual LP prices one-sided. On 2025-01-14 (156 intervals) `1e-9` cut the energy price error max from 3.99 to 0.24 $/MWh (TAS1 08:10, NSW1 14:00) and dispatch errors above 5 MW from 11 to 9, with summed solve time 530 s against 525 s.
- Any solver-option change must be checked on full-day prices against AEMO, not on the objective: equal objectives do not imply equal prices.
- Small FCAS price differences between runs at degenerate intervals (for example TAS1 `RAISEREG` at 4.72 or 5.72) come from this non-uniqueness and are expected.
- `scripts/dual_range_probe.jl` tests whether a published price is an optimal price of the fixed LP: it moves the price's rows by ±h MW and reads the one-sided duals. On the 2025 LDC benchmark (861 differing prices in 257 intervals) 220 are degenerate, including every TAS1 regulation price off by 1.00 $/MW and most LOWER6SEC/LOWER60SEC pairs; these are not model error, as AEMO leaves FCAS ties to the solver (CVP Schedule item 53). The other 641, mostly mainland raise contingency prices, have one optimal price that differs from NEMDE's and need an input or formulation diagnosis.
- Rejected for now: a secondary objective or tie-break to pick the tied vertex by rule. It is a model change needing a check against AEMO's documented tie-breaking and its own ADR; fidelity is unmeasured. The energy tie-break of [0036](0036-energy-tie-break.md) is separate.
