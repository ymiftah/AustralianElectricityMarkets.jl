# SCIP, CBC and HiGHS on cached dispatch samples

Measured on 17 October 2026 from source commit `6a8015a4dca7ccc7608d5cec301df39f09856400`, with the benchmark-only source changes archived alongside the results.

This benchmark compares the existing ordered loss-segment MILP on 12 intervals from 1 January 2026: six fast intervals at 04:05 to 04:30 and six slow intervals at 17:20 to 17:45, all AEST. It uses full cached inputs and makes no changes to dispatch formulations or production solver defaults. SOS2 is not introduced.

| Solver | Runtime version | Julia wrapper version |
| --- | --- | --- |
| HiGHS | v1.15.1 | 1.25.4 |
| SCIP | v10.0.3 | 0.12.8 |
| CBC | 2.10.13 | 1.4.0 |

Each solver runs sequentially in a fresh Julia process, with a two-interval warm-up, one requested solver thread, one BLAS thread, relative MIP gap zero, absolute gap `1e-10`, primal/dual feasibility settings `1e-7`, integrality feasibility `1e-7` and a 180-second solve limit. SCIP uses its combined feasibility tolerance for integrality. Other algorithm settings retain their defaults. Native option values are read back before the real runs, and a common independent residual check rejects a solved model if any row, bound or integrality violation exceeds `1e-6` in model units.

CBC's Julia interface does not expose constraint duals, so every fixed-binary pricing LP uses HiGHS. A public JuMP optimise hook installs a fresh backend for each dispatch and pricing solve. This keeps pricing consistent across candidates and includes solver transfer costs in the wrapper timings. The comparison therefore uses a new HiGHS reference; the earlier threading/gap benchmark timings are not directly comparable. See the [CBC interface](https://jump.dev/JuMP.jl/stable/packages/Cbc/), [SCIP parameters](https://www.scipopt.org/scip/doc/html/PARAMETERS.php) and [HiGHS 1.15.1 options](https://github.com/ERGO-Code/HiGHS/blob/v1.15.1/docs/src/options/definitions.md).

The optional solver packages live in an isolated environment that preserves the repository's existing package versions and pinned PowerSimulations source. The repository Project and Manifest files are unchanged.

SCIP is measured with all MIP starts explicitly cleared. HiGHS and CBC retain the previous-interval starts supplied by PowerSimulations. An initial SCIP run with those starts failed the objective consistency audit and is excluded from the ranking; the evidence is below. This is a configuration comparison, with that start-policy difference disclosed, rather than a controlled test of solver algorithms alone.

## Timing

| Solver | Fast execution, s | Slow execution, s | All 12 intervals, s | Speedup versus HiGHS | Native dispatch total, s | Native pricing total, s | Peak RSS, GiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| HiGHS | 41.484 | 234.752 | 276.235 | 1.00x | 205.917 | 12.083 | 4.664 |
| SCIP | 42.611 | 86.211 | 128.822 | 2.14x | 61.866 | 3.707 | 4.920 |
| CBC | 47.666 | 67.418 | 115.084 | 2.40x | 47.370 | 12.672 | 4.684 |

Execution covers interval updates, fingerprinting, dispatch, pricing, residual checks and result storage. It excludes package loading, warm-up, construction and comparison with NEMDE. Native times are the solvers' reported times and exclude JuMP model transfer. These are selected-window measurements, one run per candidate, rather than full-day speed estimates.

| Solver | Dispatch copy plus solve, s | Pricing copy plus solve, s | Matrix fingerprinting, s | System and simulation construction, s | Construction plus execution, s |
| --- | ---: | ---: | ---: | ---: | ---: |
| HiGHS | 213.639 | 20.023 | 5.494 | 48.008 | 324.244 |
| SCIP | 70.842 | 11.733 | 6.090 | 48.025 | 176.847 |
| CBC | 52.810 | 19.625 | 5.942 | 47.718 | 162.803 |

Construction totals cover a separate system and simulation for each window, excluding package loading, warm-up, comparisons and the separate update-cost probe.

## Solution comparison

| Solver | Max absolute objective difference | Max relative objective difference | Max dispatch difference, MW | Max regional price difference, $/MWh | Max FCAS price difference | Max flow difference, MW | Max loss difference, MW |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| HiGHS | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| SCIP | 3.10689e-06 | 2.83455e-13 | 1.93215e-06 | 3.37508e-13 | 1.08885e-12 | 1.90863e-06 | 2.86788e-08 |
| CBC | 2.16067e-07 | 2.15329e-14 | 1.93215e-06 | 2.84217e-14 | 1.08885e-12 | 1.90863e-06 | 2.86788e-08 |

Differences are against the new HiGHS result for the same interval. Objectives use native model cost scaling. Prices come from the common fixed-binary pricing LP. All checked modeled outputs are finite; missing-output coverage and published comparison values are checked against the reference.

Energy-price mean absolute error against published NEMDE outcomes, in $/MWh, over the completed windows:

| Region | HiGHS | SCIP | CBC |
| --- | ---: | ---: | ---: |
| NSW1 | 0.0304778 | 0.0304778 | 0.0304778 |
| QLD1 | 0.0933426 | 0.0933426 | 0.0933426 |
| SA1 | 0.781595 | 0.781595 | 0.781595 |
| TAS1 | 0.683372 | 0.683372 | 0.683372 |
| VIC1 | 0.00116423 | 0.00116423 | 0.00116423 |

## SCIP start-path diagnostic

The initial SCIP run accepted prior-interval starts and reported optimal status on all 12 dispatches, but its fixed-binary pricing LP improved the objective materially on eight intervals. The largest improvement was 236,191,677 in the model objective units. Such an improvement contradicts the claimed MIP optimum, so those timings and solutions are excluded from the accepted comparison. They are retained under `scip_with_starts_invalid/` with the original solver log.

A two-interval replay reproduced this discrepancy. At 04:10, SCIP reported an objective of 19,887,404.2891 with the supplied starts; explicitly clearing starts gave 18,799,008.8435. Recomputing the original objective from the returned variable values agreed with the native reported values, so this is not merely an objective display discrepancy. The exact second-interval model was exported to MPS, with starts omitted, and solved independently by all three solvers: each returned 18,799,008.8435, agreeing within `1e-5`. All three also passed a tiny deliberately poor-start test.

This isolates the observed failure to the start-enabled replay path in this SCIP configuration. It does not establish whether the underlying cause is the solver, its Julia interface, or interaction with the replay integration. The rerun explicitly clears starts before every MIP and checks native versus original-expression objectives and dispatch versus fixed-binary pricing objectives. No automatic retry or alternate-solver fallback is used.

## Coverage and validation

| Solver | Window | Dispatch attempts | Optimal dispatches | Optimal pricing LPs | Comparison exported |
| --- | --- | ---: | ---: | ---: | --- |
| HiGHS | fast | 6 | 6 | 6 | True |
| HiGHS | slow | 6 | 6 | 6 | True |
| SCIP | fast | 6 | 6 | 6 | True |
| SCIP | slow | 6 | 6 | 6 | True |
| CBC | fast | 6 | 6 | 6 | True |
| CBC | slow | 6 | 6 | 6 | True |

A non-optimal solve is recorded and rejected; it does not become an accepted dispatch or price comparison. Within the measured-window loop, a failed window does not prevent the other window or solver from being attempted. A failed warm-up is visible in the profile log and can prevent measured windows from starting. Native logs and any `failure.txt` retain the reason.

| Solver | Max row violation | Max bound violation | Max integrality violation | Max absolute incumbent/bound difference | MIP matrix fingerprints equal to HiGHS |
| --- | ---: | ---: | ---: | ---: | --- |
| HiGHS | 1.90347e-08 | 1.90347e-08 | 6.21725e-15 | 3.35276e-08 | 12 / 12 |
| SCIP | 3.07341e-13 | 4.84057e-14 | 9.03944e-13 | 0 | 0 / 12 |
| CBC | 3.38476e-14 | 2.84217e-14 | 1.11022e-16 | 3.72529e-09 | 0 / 12 |

| Solver | Consistent dispatch/pricing pairs | Max absolute objective difference |
| --- | ---: | ---: |
| HiGHS | 12 / 12 | 1.32248e-07 |
| SCIP | 12 / 12 | 3.11062e-06 |
| CBC | 12 / 12 | 2.16067e-07 |

The consistency audit uses `1e-5 + 1e-9 * max(abs(MIP objective), abs(LP objective))` as a numerical comparison tolerance, separate from the configured zero relative MIP gap.

The fingerprints cover the ordered pre-solve constraint matrix, row/column bounds, objective coefficients and constant, and integer-column indices. These raw ordered hashes differ between independently constructed profiles, so they do not establish identical model arrays here. Row and column ordering and floating-point assembly can affect such hashes; their exact cause was not established. All profiles use the same cached inputs, replay source and formulation, with matching dimensions and binary counts. The independent MPS diagnostic controls the exact mathematical model for one interval. Residuals are independently recomputed against those constraints and bounds, rather than inferred only from solver status. Small floating-point incumbent/bound differences are reported even when native status is optimal.

The lowest observed execution time among completed candidates is CBC, 115.084 seconds (2.40x versus HiGHS). Output differences and NEMDE errors above remain part of the decision; this benchmark does not select a new production default.

## Reproduction and artifacts

The root artifact directory contains the isolated `environment/Project.toml` and `environment/Manifest.toml`, `setup.jl`, solver logs, `timings.csv`, `objectives.csv`, `changes.csv`, `changed_values.csv`, `nemde_errors.csv`, `solves.csv`, `coverage.csv`, `fingerprints.csv`, analysis/verification scripts, the toy handoff test, `objective_audit.csv`, start-path diagnostic scripts/logs/exported MPS and source snapshots.

With that environment available, run one candidate in a fresh process and output directory:

```bash
julia --project=<artifact_root>/environment --threads=1 \
    AustralianElectricityMarketsSimulations/scripts/benchmark_solvers.jl \
    /run/media/simba/Store/aem_validation/stock_sim/new_solver_run scip 6 180 true
```

The final Boolean argument explicitly clears all MIP starts. Use `true` for the accepted SCIP configuration; use `false` for the measured HiGHS/CBC configuration. The benchmark script is experimental tooling and is not part of the production dispatch path.

Raw artifacts: `/run/media/simba/Store/aem_validation/stock_sim/solver_compare_20261017T174946`.
