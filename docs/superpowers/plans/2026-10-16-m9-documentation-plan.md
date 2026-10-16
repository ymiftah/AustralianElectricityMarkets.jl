# M9: documentation and follow-ups for the stock Simulation replay

Date: 2026-10-16. Branch: `stock-simulation-v02` (draft PR #196). Parent plan:
`2026-10-14-stock-simulation.md` (kept locally; this file is the committed record for M9).

## State at the end of M8

- `replicate_range(db, start, stop)` builds one system and one recurrent `DecisionModel`
  (horizon 1) per trading day and steps a stock `PSI.Simulation`. Every per-interval input is a
  `SingleTimeSeries`; every family reads its data from PSI parameters (energy bids, ramps,
  generic-constraint RHS and invoked mask, battery ceilings, interconnector losses, MNSP, FCAS,
  tie-break scales). Constraint coefficients that change per step use the PSI
  `ConstraintCoefficientParameter`.
- PowerSimulations is pinned to the fork `ymiftah/PowerSimulations.jl`, branch `aem-simulation`
  (coefficient parameter, store dataset-name escaping for `/`, cached `is_milp`).
- Measured on real data (hive cache, 2026-01-01 from 04:05, in-memory time series, one chunk):

| steps | peak RSS | system | sim build | execute | compare |
| --- | --- | --- | --- | --- | --- |
| 24 | 3.81 GiB | 14.4 s | 5.5 s | 100 s | 13.8 s |
| 72 | 3.91 GiB | 16.8 s | 6.7 s | 862 s | 18.7 s |
| 144 | 4.17 GiB | 19.1 s | 8.7 s | 2198 s | 25.4 s |
| 288 | 4.14 GiB | 24.4 s | 12.6 s | 3251 s | 39.2 s |

  Per step at 288 steps: optimize 7.8 s, parameter update 1.27 s, dual pass 1.74 s, state update
  0.20 s. A full day costs about 55 minutes, 11.5 s per interval, against 24 s per interval for
  `replicate_interval` (v0.2 after #195). The HiGHS time is the same in both paths.

- Equality with the per-interval path: first hour (12 intervals) MATCH within 1e-11; six midday
  intervals identical to every printed digit.

## ADR 0053: stock Simulation replay

Decision record covering:

- one `DecisionModel` per trading day stepped by `PSI.Simulation` (chunk = trading day because
  the tied-pair set and the invoked generic-constraint union depend on the day, memory grows
  with the range, and the price cap changes on the financial-year boundary at the interval
  ending 00:05 on 1 July);
- all per-interval inputs as `SingleTimeSeries` transformed at a one-interval horizon (no
  directly built `Deterministic` windows, no change to InfrastructureSystems);
- every family reads parameters, no build-time constants; the neutralisation of absent items
  (zero-cost slack for non-invoked generic constraints, zero widths for FCAS offers and zero-width
  tie bands, inactive enablement limits);
- results reopened from disk per chunk, published outcomes read once per table;
- `replicate_interval` stays a standalone `DecisionModel` solve sharing the formulations;
  lookahead stays standalone-only; the three remaining `built_for_recurrent_solves` guards;
- measurements above and the first-call compilation finding (a cold process pays about 135 s;
  the precompile workload brings a first 12-step chunk from 388 s to 106 s and costs a 5.5 minute
  precompile needing 9-10 GiB, repaid after any Simulations source or PSI pin change).

## ADR 0054: constraint-coefficient parameters and reformulations

- Projection argument: with a fixed constraint matrix and data only in right-hand sides, bounds
  and objective coefficients, the facet slopes of any projection come from a finite fixed set, so
  a slope that varies continuously with the data needs a coefficient parameter.
- The PSI extension: `ConstraintCoefficientParameter`, Float64 storage, targets
  (constraint, variable, scale), `JuMP.set_normalized_coefficient` after the stock update;
  fork commits `bb5988d` (PR ymiftah/PowerSimulations.jl#3), `91a8018` (store escaping),
  `fc30a29` (cached `is_milp`); PR #4 (batch binder) under review.
- Losses: `L(f, D) = L(f, 0) + k(D) f` (AEMO loss equation is linear in regional demand), with the
  demand-dependent term as one coefficient per interconnector per step; segment widths, binaries
  and slopes are demand independent.
- FCAS: effective offers (scaled trapezium, enablement mask, slopes, band widths) precomputed as
  derived series; slopes through the coefficient parameter; disabled offers encoded with zero
  widths and slopes and +/-1e5 MW enablement limits.
- Tie-breaks: per-band scale w/w_ref series feeding a two-dimensional coefficient parameter; the
  energy bid curves keep zero-width bands so the pair set is stable within a trading day;
  pre-flight check on the tied-pair set; chained ties throw.
- AEMO sources: FCAS Model in NEMDE sections 4 to 6, Constraint FAQ 3.19, CVP items 37 and 53,
  Marginal Loss Factors methodology section 3.1 and 4, Loss factor methodology.
- Departures from AEMO: none introduced; list the pre-existing ones from the gap analysis.

## Documentation

- `docs/src/replay.md` (added in M8): check against the final API (`chunks`, `results`,
  `solver_stats`, `store_parameters`, `output_dir`, `time_series_directory`).
- `docs/validation/dispatch-comparison.md` lives on `compare-gate6`: add the full-day section
  (below) when that branch is merged, or port the section.
- `CHANGELOG.md` `[Unreleased]`: one entry per user-visible change is in place; add the
  precompile and pin notes if missing.
- No docstring may cite an ADR; ADRs carry the rationale.

## Validation record to port into `docs/validation/dispatch-comparison.md`

Full day 2026-01-01 04:05 to 2026-01-02 04:00 (288 intervals), AEMSim minus NEMDE:

| region | mean abs ROP gap | median | within $1 |
| --- | --- | --- | --- |
| NSW1 | 1.54 | 0.00 | 77% |
| QLD1 | 1.84 | 0.00 | 80% |
| SA1 | 6.94 | 4.57 | 20% |
| VIC1 | 8.92 | 6.23 | 19% |
| TAS1 | 33.71 | 15.65 | 7% |

FCAS prices 96.8% within tolerance; dispatch 97.4% within 1 MW (6.1% rows missing); interconnector
flow mean gap 41.8 MW (47% within 5 MW); loss mean gap 2.93 MW. Worst hours 11:00 to 16:00
(mean ROP gap 18 to 28). Per-interval path cross-check at 05:00, 09:00, 11:00, 12:00, 13:10 and
14:00 gives the same solved values, so the gaps belong to the model. The gap analysis and next
bridges are in `2026-10-16-gap-analysis.md` (local).

## Follow-ups (not in M9)

1. Tie-break containers: register the slacks and rows as named PSI containers (region, tie group,
   t), keep the network-objective hook as the entry point, report their slacks in
   `_constraint_violations`.
2. PSI coefficient binder (PR #4 review): remove the O(N^2) duplicate-pair scan, add a key-based
   batch overload and a vector form of the explicit call, skip unchanged values per step, add
   scale and Simulation tests, drop unrelated formatting churn.
3. Upstream the coefficient parameter, the store-name escaping and the `is_milp` cache to
   Sienna-Platform/PowerSimulations.jl once PR #4 settles (needs CLA confirmation).
4. Replace the private PSI reads (`_read_results`, `_process_timestamps`) with public API or
   upstream a batched dual/variable reader.
5. Export per-interval violations and skipped constraints from `replicate_range` to CSV.
6. Wire `replicate_range` into `scripts/compare_dispatch.jl` (on another branch).
7. Run the same-interval HiGHS comparison for hard hours (07:25, 12:00) to check the
   non-invoked-row degeneracy does not slow solves; consider presolve options.
8. Close the gaps listed by the gap analysis.
