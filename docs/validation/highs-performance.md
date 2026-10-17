# HiGHS replay profiling and threading probe

## Method

Measured on 17 October 2026, from `stock-simulation-v02` at `6a8015a4dca7ccc7608d5cec301df39f09856400`, with Julia 1.13.1 and HiGHS 1.15.1. The host is an AMD Ryzen 9 5900HS with 8 physical cores, 16 logical threads and approximately 14 GiB usable RAM.

Each configuration runs in a fresh Julia process with one Julia thread, first warming the build and execution paths on two intervals. The measured windows contain six five-minute dispatch intervals each, all in AEST on 1 January 2026:

- Fast: 04:05 to 04:30.
- Slow: 17:20 to 17:45.

The existing fully populated `/home/simba/.nemdb_cache` is read without population. Every configuration uses all replication parts and the same strict input checks, `mip_rel_gap=0.0` and `mip_abs_gap=1e-10`. Solver feasibility tolerances, formulations and production defaults are unchanged. Detailed solver logs use `highs_analysis_level=384` and `log_to_console=false`.

| Profile | `threads` | `parallel` |
| --- | ---: | --- |
| serial1 | 1 | off |
| parallel2 | 2 | on |
| parallel4 | 4 | on |
| automatic | 0 | choose |

The automatic profile reports eight HiGHS threads and main-tree parallel search off in its solver logs.

These are single pilot measurements on selected windows. They are not a full-day speed estimate or a statistical estimate of variability. The first interval of each window has no preceding optimized warm start; the short windows also omit generic constraints never invoked within them. Compare configurations within this experiment, rather than treating their absolute timings as directly comparable to the earlier full-day run.

Execution times exclude system construction, simulation construction, warm-up, package loading and result comparison. Separate construction timings are retained in the CSV files. The diagnostic flag adds timing instrumentation equally to every profile.

## Reproduction

Run one configuration per process, sequentially, using a fresh output directory:

```bash
julia --project=AustralianElectricityMarketsSimulations/test --threads=1 \
    AustralianElectricityMarketsSimulations/scripts/benchmark_highs.jl \
    /run/media/simba/Store/aem_validation/stock_sim/highs_serial1_new \
    1 off /home/simba/.nemdb_cache 6 384
```

Repeat with the other profiles in the table. The final argument can be `0` for a run without detailed diagnostic timing. Each window writes phase and step CSVs, individual backend logs, and dispatch/price comparisons with published NEMDE outcomes. A backend log can contain one pricing LP followed by the next interval's MIP; MIP warm-start repair LPs are part of dispatch optimization, not the pricing pass.

## Measurements

| Profile | Fast execution, s/interval | Slow execution, s/interval | Execution for all 12, s | Change versus automatic |
| --- | ---: | ---: | ---: | ---: |
| serial1 | 4.888 | 43.906 | 292.765 | +15.6% |
| parallel2 | 4.689 | 37.350 | 252.231 | -0.4% |
| parallel4 | 4.679 | 37.445 | 252.743 | -0.2% |
| automatic | 4.911 | 37.292 | 253.214 | +0.0% |

| Profile | Mean dispatch optimization, s/interval | Mean pricing wrapper, s/interval | System + simulation construction for both windows, s | Peak RSS, GiB |
| --- | ---: | ---: | ---: | ---: |
| serial1 | 20.524 | 1.790 | 46.368 | 4.354 |
| parallel2 | 17.310 | 1.782 | 45.959 | 4.570 |
| parallel4 | 17.347 | 1.674 | 46.450 | 4.384 |
| automatic | 17.273 | 1.880 | 46.782 | 4.771 |

## Solver work

The serial slow window spends 213.06 of 237.12 seconds of internal MIP time (89.9%) in 415 nested sub-MIP calls. All six main MIPs finish at one processed node. The expensive work is repeated root processing, heuristics and nested MIPs, rather than a large main branch-and-bound tree.

| Profile | Slow-window internal MIP time, s | Nested MIP time, s | Nested MIP calls | Main nodes per interval |
| --- | ---: | ---: | ---: | --- |
| serial1 | 237.12 | 213.06 | 415 | 1, 1, 1, 1, 1, 1 |
| parallel2 | 198.70 | 175.96 | 415 | 1, 1, 1, 1, 1, 1 |
| parallel4 | 199.67 | 176.12 | 415 | 1, 1, 1, 1, 1, 1 |
| automatic | 198.12 | 175.30 | 415 | 1, 1, 1, 1, 1, 1 |

HiGHS restricts each nested sub-MIP branch-and-bound search to one worker; other solver work can still use threads. See the versioned [`getMaxNumWorkers` implementation](https://github.com/ERGO-Code/HiGHS/blob/v1.15.1/highs/mip/HighsMipSolver.h#L149-L155) and [parallelism documentation](https://github.com/ERGO-Code/HiGHS/blob/v1.15.1/docs/src/parallel.md). The timing comparison, rather than main-node count alone, determines the observed benefit.

The original models contain between 134,549 and 134,966 columns. Initial presolve leaves between 8,675 and 12,187 columns. 509 to 521 binary columns survive initial presolve. Raw model counts therefore substantially overstate the size solved after presolve; removing already-eliminated structure mainly targets construction, transfer, memory and presolve overhead.

The progress timestamps place the first root-relaxation bound about 0.0 to 0.2 seconds after the initial zero-iteration progress line. These timestamps have 0.1-second resolution and can include intervening root work; they are not a dedicated precise root-LP timer. They distinguish the cheap initial relaxation from the expensive repeated root and heuristic work.

The serial pricing wrapper averages 1.790 seconds per interval, while the corresponding internal HiGHS LP runtime averages 0.996 seconds. 10 of the 12 pricing LPs report a useful basis and skip presolve; the first pricing LP in each window is presolved. The basis/presolve decision and wrapper overhead warrant a separate controlled experiment. The harness does not establish their exact cause. PSI's existing `solver_solve_time` CSV field remains NaN; internal times here come from the solver logs.

## Output checks

All 48 measured intervals terminated optimally. All modeled numeric outputs checked are finite, and missing-output coverage is identical to the reference. Comparisons cover objectives, modeled dispatch, regional energy prices, FCAS prices, interconnector flows and interconnector losses.

| Quantity | Maximum absolute difference from serial1 | Maximum absolute difference from previous full-day run |
| --- | ---: | ---: |
| objective | 0 | 0 |
| dispatch_mw | 0 | 7.39e-13 |
| regional_rop | 0 | 2.17e-13 |
| fcas_rop | 0 | 3.55e-15 |
| interconnector_flow | 0 | 1.11e-12 |
| interconnector_loss | 0 | 7.61e-13 |

These are consistency checks against the current formulation, not a claim that its existing NEMDE errors are resolved. Per-window `nemde_summary.csv` files retain the comparison with published outcomes.

## Interpretation

The lowest measured execution time is parallel2: 252.231 seconds, compared with 253.214 seconds for the current automatic settings. Explicit two- and four-thread profiles differ from automatic by less than 0.4%, so this pilot provides no material reason to change the production threading defaults. A fully single-threaded solve is slower. These single runs do not establish a statistically reliable winner or a full-day speedup. Production defaults remain unchanged.

The strongest new lead is the nested heuristic MIP workload. The follow-up below tests `mip_heuristic_effort` while retaining the current optimality and feasibility tolerances. Interval-level process parallelism and pricing basis/presolve handling remain separate opportunities.

## Artifacts

Raw outputs: `/run/media/simba/Store/aem_validation/stock_sim/highs_threads_20261017T122220`.

The output root contains `timings.csv`, `validation.csv`, `solver_phases.csv`, the analysis scripts and a source snapshot. Each profile has metadata, warm-up logs and measured `fast` and `slow` directories. Times reported from HiGHS logs are rounded by HiGHS itself.

## Heuristic effort follow-up

A second experiment varies only `mip_heuristic_effort`: 0.05 (the default), 0.01 and 0.0. It repeats the same two six-interval windows in fresh processes, with automatic HiGHS threading (`threads=0`, `parallel="choose"`), the same strict input checks and the same gap and feasibility tolerances. Every experimental solve has a common 180-second time limit. The benchmark rejects a configuration with any non-optimal dispatch result. Production settings are unchanged.

| Heuristic effort | Fast execution, s | Slow execution, s | All 12 intervals, s | Change versus fresh default | Mean dispatch, s/interval | Mean pricing, s/interval |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.05 | 28.800 | 219.341 | 248.141 | +0.0% | 16.925 | 1.720 |
| 0.01 | 29.107 | 212.238 | 241.344 | -2.7% | 16.334 | 1.737 |
| 0 | 28.586 | 218.146 | 246.733 | -0.6% | 16.745 | 1.778 |

Construction, comparison, package loading and warm-up are excluded from execution times. These are selected-window pilot runs, not a full-day speed estimate.

| Heuristic effort | Slow-window internal MIP time, s | Nested MIP calls | Nested MIP time, s | Main nodes per interval |
| ---: | ---: | ---: | ---: | --- |
| 0.05 | 193.96 | 415 | 171.43 | 1, 1, 1, 1, 1, 1 |
| 0.01 | 186.93 | 394 | 164.31 | 1, 1, 1, 1, 1, 1 |
| 0 | 192.34 | 392 | 168.63 | 1, 1, 1, 1, 1, 1 |

In this HiGHS version, zero effort does not disable every heuristic. The main solver permits an initial allowance of 10,000 heuristic LP iterations, and nested sub-MIPs receive an internal effort setting of 0.8. See the versioned [main heuristic-budget implementation](https://github.com/ERGO-Code/HiGHS/blob/v1.15.1/highs/mip/HighsMipSolverData.cpp#L633-L651) and [nested-MIP options](https://github.com/ERGO-Code/HiGHS/blob/v1.15.1/highs/mip/HighsPrimalHeuristics.cpp#L106-L116). The effort value is an effort-budget control, not an off switch for all heuristic algorithms.

All 36 measured dispatch solves and 36 pricing LPs reached optimality. All checked modeled values are finite and missing-output coverage is unchanged.

| Quantity | Maximum absolute difference from fresh default | Maximum absolute difference from original full-day run |
| --- | ---: | ---: |
| objective | 0 | 0 |
| dispatch_mw | 0 | 7.39e-13 |
| regional_rop | 0 | 2.17e-13 |
| fcas_rop | 0 | 3.55e-15 |
| interconnector_flow | 0 | 1.11e-12 |
| interconnector_loss | 0 | 7.61e-13 |

The lowest observed execution time is effort 0.01, with 241.344 seconds versus 248.141 seconds for the fresh default (2.7% lower). A single selected-window measurement does not establish a reliable improvement or justify changing production defaults. Solver work counts and output differences above must be considered alongside the wall times.

Reproduce a configuration with a fresh output directory, setting the last two arguments to the requested effort and solve limit:

```bash
julia --project=AustralianElectricityMarketsSimulations/test --threads=1 \
    AustralianElectricityMarketsSimulations/scripts/benchmark_highs.jl \
    /run/media/simba/Store/aem_validation/stock_sim/highs_effort_new \
    0 choose /home/simba/.nemdb_cache 6 384 0.01 180
```

Raw follow-up outputs: `/run/media/simba/Store/aem_validation/stock_sim/highs_effort_20261017T134030`. The root contains `timings.csv`, `validation.csv`, `solver_phases.csv`, the analysis scripts and a source snapshot. Each profile also retains its comparison with published NEMDE outcomes.

## MIP gap experiment

This experiment varies only the relative MIP gap: zero, `1e-8`, `1e-7`, `1e-6`, `1e-5` and `1e-4`. The zero-gap reference reuses the recent `default005` run from the heuristic-effort experiment, with its CSV files and solver logs copied into this experiment. Five new configurations use the same two six-interval windows, each in a fresh Julia process with a two-interval warm-up. The input cache, model, automatic threading, heuristic effort 0.05, absolute gap `1e-10`, feasibility tolerances, analysis level 384 and 180-second solve limit are unchanged. The `1e-7` configuration was added after `1e-6` changed fast-window outputs, to resolve the gap between that result and the unchanged `1e-8` result. Production defaults are unchanged.

The [versioned HiGHS options](https://github.com/ERGO-Code/HiGHS/blob/v1.15.1/docs/src/options/definitions.md#mip_rel_gap) define relative gap as `abs(upper_bound - lower_bound) / abs(upper_bound)`. A solver status of optimal at a nonzero configured gap means optimal within that gap; it does not establish the zero-gap optimum.

| Relative gap | Gap, % | Fast execution, s | Slow execution, s | All 12 intervals, s | Speedup versus zero gap | Mean dispatch, s | Mean pricing, s |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 0 | 28.800 | 219.341 | 248.141 | 1.00x | 16.925 | 1.720 |
| 1e-08 | 1e-06 | 28.720 | 206.547 | 235.267 | 1.05x | 15.724 | 1.846 |
| 1e-07 | 1e-05 | 27.664 | 178.796 | 206.459 | 1.20x | 13.429 | 1.787 |
| 1e-06 | 0.0001 | 27.662 | 52.900 | 80.561 | 3.08x | 2.942 | 1.819 |
| 1e-05 | 0.001 | 26.893 | 34.525 | 61.418 | 4.04x | 1.334 | 1.710 |
| 0.0001 | 0.01 | 27.479 | 33.574 | 61.053 | 4.06x | 1.291 | 1.826 |

Execution includes interval updates, dispatch and pricing. Package loading, warm-up, system/model construction and comparisons are excluded. Timing comparisons use a reused baseline and one measurement per setting, so they are pilot observations rather than a full-day speed estimate.

| Relative gap | System and simulation construction, s | Construction plus execution, s |
| ---: | ---: | ---: |
| 0 | 46.939 | 295.080 |
| 1e-08 | 48.975 | 284.242 |
| 1e-07 | 47.357 | 253.817 |
| 1e-06 | 47.878 | 128.440 |
| 1e-05 | 47.775 | 109.193 |
| 0.0001 | 47.015 | 108.068 |

Construction totals cover a separate system and simulation model for each window. They exclude package loading, warm-up, comparison and the separate update-cost probe.

| Relative gap | Max objective increase | Max relative objective increase | Max dispatch change, MW | Max regional price change, $/MWh | Max FCAS price change | Max flow change, MW | Max loss change, MW |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 1e-08 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 1e-07 | 0.130171 | 1.57246e-08 | 0.377228 | 4.14086 | 3.55271e-15 | 0.378011 | 0.00434738 |
| 1e-06 | 7.42245 | 6.31209e-07 | 18.8364 | 7.00175 | 5.09025 | 10.8364 | 0.373673 |
| 1e-05 | 133.61 | 9.03603e-06 | 51.4611 | 15.0533 | 5.09025 | 71.1599 | 4.90171 |
| 0.0001 | 372.526 | 2.796e-05 | 77.8866 | 285.04 | 266.96 | 60 | 4.90171 |

All differences above are against the zero-gap solution for the same interval. Objective values retain the model's native cost scaling. Relative objective accuracy does not bound the error in prices obtained from the separate fixed-binary pricing LP.

At 04:15, relative gap `1e-7` increases the objective by only 0.130 units. Heywood flow changes by 0.378 MW, and the SA energy price changes from $13.241/MWh to $9.100/MWh.

At 04:20, relative gap `1e-6` increases the objective by 7.422 units on a baseline of 11759111.129. TUNGATIN dispatch falls by 18.836 MW, from 79.929 MW to 61.092 MW. This illustrates why an objective tolerance alone is insufficient to select a setting for dispatch replication.

At 04:05, relative gap `1e-4` changes the Tasmania energy price from $65.12/MWh to $350.16/MWh. The price changes by $285.04/MWh despite the small relative objective tolerance.

| Relative gap | Regional prices changed > 1e-5 | FCAS prices changed > 1e-5 | Dispatch targets changed > 1e-5 MW |
| ---: | ---: | ---: | ---: |
| 0 | 0 / 60 | 0 / 600 | 0 / 6132 |
| 1e-08 | 0 / 60 | 0 / 600 | 0 / 6132 |
| 1e-07 | 1 / 60 | 0 / 600 | 3 / 6132 |
| 1e-06 | 10 / 60 | 16 / 600 | 20 / 6132 |
| 1e-05 | 25 / 60 | 22 / 600 | 74 / 6132 |
| 0.0001 | 24 / 60 | 51 / 600 | 108 / 6132 |

Regional energy-price mean absolute error against published NEMDE outcomes, in $/MWh, over the 12 intervals:

| Region | Zero gap | 1e-8 | 1e-7 | 1e-6 | 1e-5 | 1e-4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| NSW1 | 0.0304778 | 0.0304778 | 0.0304778 | 0.0427767 | 0.312892 | 1.47924 |
| QLD1 | 0.0933426 | 0.0933426 | 0.0933426 | 0.101989 | 0.103656 | 0.0983426 |
| SA1 | 0.781595 | 0.781595 | 1.12667 | 1.5961 | 3.12184 | 2.53294 |
| TAS1 | 0.683372 | 0.683372 | 0.683372 | 1.65485 | 2.76248 | 31.5576 |
| VIC1 | 0.00116423 | 0.00116423 | 0.00116423 | 0.0303309 | 0.752832 | 1.32606 |

All 60 new dispatch solves reached optimal status at their configured gaps, and all 60 new pricing LPs reached optimality. Every checked modeled output is finite, output coverage is unchanged, and published comparison values match the reference.

| Relative gap | Max gap from printed bounds, % | Max reported absolute gap | Slow nested MIP calls | Max bound violation | Max row violation | Max integrality violation |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 0 | 0 | 415 | 0 | 0 | 8.08242e-14 |
| 1e-08 | 9.84016e-07 | 0.1455 | 374 | 0 | 0 | 8.08242e-14 |
| 1e-07 | 9.99833e-06 | 1.4693 | 341 | 0 | 0 | 8.88178e-16 |
| 1e-06 | 9.36656e-05 | 15.094 | 48 | 0 | 0 | 8.88178e-16 |
| 1e-05 | 0.000946338 | 139.93 | 6 | 0 | 0 | 8.88178e-16 |
| 0.0001 | 0.00300528 | 394.456 | 4 | 0 | 0 | 2.66454e-15 |

Achieved gaps are calculated from printed bounds in the solver reports, which have limited precision; feasibility violations are also reported by the solver. `objectives.csv` retains full-precision stored objectives. `changed_values.csv` lists output changes above `1e-5`, and `nemde_errors.csv` includes region-level energy and FCAS error summaries.

The fastest tested setting with no checked output changes above `1e-5` is relative gap `1e-08`: 235.267 seconds, versus 248.141 seconds at zero gap (1.05x faster). This is a candidate for broader validation, not a guarantee for other intervals.

Looser gaps must be judged against both dispatch and NEMDE-price errors above. A nonzero gap is an accuracy choice, and this experiment does not change production defaults.

Reproduce a configuration with a fresh output directory; the last two arguments are relative and absolute MIP gaps:

```bash
julia --project=AustralianElectricityMarketsSimulations/test --threads=1 \
    AustralianElectricityMarketsSimulations/scripts/benchmark_highs.jl \
    /run/media/simba/Store/aem_validation/stock_sim/highs_gap_new \
    0 choose /home/simba/.nemdb_cache 6 384 0.05 180 1e-6 1e-10
```

Raw outputs: `/run/media/simba/Store/aem_validation/stock_sim/highs_gaps_20261017T151249`. The root contains timing, objective, output-change, NEMDE-error and solver-phase CSV files, analysis scripts, option read-back verification, baseline provenance and source snapshots.
