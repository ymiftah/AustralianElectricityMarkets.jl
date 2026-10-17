# Development note: complete-input replay and solver performance

Date: 17 October 2026. Worktree: `/home/simba/.julia/dev/AEM-gate6`.
Branch: `stock-simulation-v02`, behind draft PR
[#196](https://github.com/ymiftah/AustralianElectricityMarkets.jl/pull/196).

The session started from the clean, pushed revision `e4974f7`. It first investigated differences
between historical replay and NEMDE, then removed silent input substitutions, populated the
missing cache data and validated a full trading day. Subsequent work measured runtime, explored
acceleration options and compared HiGHS, SCIP and CBC on selected intervals.

The principal outcomes are:

- Complete inputs reduced regional price mean absolute error from 10.590333 to 0.302533 AUD/MWh.
- Missing inputs now cause named errors rather than selecting a different dispatch formulation.
- The corrected full-day replay completed all 288 intervals optimally in 65.18 minutes including
  initial system and model construction.
- On a separate 12-interval benchmark, CBC reduced execution from 276.235 to 115.084 seconds
  while preserving prices to floating-point precision. This remains a sample result.
- Loosening the MIP objective gap can save substantial time while materially changing dispatch
  and prices. Production gap settings and the default solver remain unchanged.

## 1. Diagnosis, implementation and cache repair

The original investigation was read only. After the cause was identified, implementation,
cache population and simulation runs were explicitly requested.

The largest error came from an existing MNSP fallback. When the January replay did not find
Basslink offers, the setter warned and continued with a free-flowing interconnector. That changed
its offer costs, directional limits and loss allocation. An optimal solve of that substituted
model was therefore not evidence of a faithful reconstruction.

The correction determines regulated versus MNSP status from effective-dated
`INTERCONNECTORCONSTRAINT.ICTYPE`, independently of whether the offer query returns rows. An
MNSP requires both registered directional links, terminal loss factors, selected offers, price
bands, quantities and availability for every interval. Validation occurs before attached series
are replaced. Missing, non-finite or invalid inputs are rejected; an explicitly regulated
interconnector does not require MNSP offers. A replay range cannot cross an unsupported change in
classification.

The same completeness contract was extended to energy-bid coverage, regional demand, dispatch
limits, invoked generic-constraint definitions, contributing terms, penalty weights and template
coverage. Missing regional demand cannot silently remove a region from the constructed topology.
Structural elimination of an equation whose contributing devices are all unavailable is recorded
separately from missing-input or unsupported-equation failures.

The investigation also found omitted participant fixed-loading constraints. These are now
reconstructed from submitted energy `FIXEDLOAD` offers, with their invocation masks and penalty
factor 380. The existing implementation excludes units offering a fast-start profile; strict
replay rejects an invoked fixed-loading constraint that remains unresolved for that reason.
BLOWERNG subsequently matched published dispatch exactly, and HUMENSW's largest gap fell to
approximately 0.0000038 MW.

The primary cache at `/home/simba/.nemdb_cache` was populated for December 2025 and January 2026
for `MNSP_DAYOFFER`, `MNSP_BIDOFFERPERIOD` and `DISPATCH_MNSPBIDTRK`. The preceding month matters
because an interval's selected offer can refer to an earlier submission. Existing effective-dated
standing data and terminal factors were also validated. Later performance experiments read this
populated cache without additional population.

The formulation checks used AEMO's Electricity Data Model Report v5.7.0, including
`INTERCONNECTORCONSTRAINT` (pp. 404-406), `MNSP_INTERCONNECTOR` (pp. 517-518), and the MNSP offer
and tracking tables. Participant fixed loading follows AEMO's Schedule of Constraint Violation
Penalty Factors v8.0, item 13, within pp. 13-17. The pending `docs-intro-to-psi-nem` documentation,
its formulation audit and the existing implementation notes supplied context; they were not
treated as proof that every NEMDE mechanism was already implemented.

Implementation and validation are committed and pushed as
`6a8015a4dca7ccc7608d5cec301df39f09856400`, **Require complete inputs for NEM dispatch replay**.
The public usage and cache requirements are documented in [Replay a range of dispatch intervals](../src/replay.md).

## 2. Full-day validation against NEMDE

The corrected run covers 288 five-minute intervals ending from 1 January 2026 04:05 through
2 January 2026 04:00, all AEST. It uses all default replication parts,
`interval_flow_limits=false`, `mip_rel_gap=0.0` and `mip_abs_gap=1e-10`.

| Metric | Original replay | Complete-input replay |
| --- | ---: | ---: |
| Regional ROP mean absolute error, AUD/MWh | 10.590333 | 0.302533 |
| FCAS ROP mean absolute error, all regions, AUD/MWh | 0.486194 | 0.007738 |
| Interconnector flow mean absolute error, MW | 41.776653 | 1.520848 |
| Interconnector loss mean absolute error, MW | 2.926460 | 0.129269 |
| Modelled dispatch rows within 1 MW | 97.3717% | 99.0671% |

All 288 intervals terminated optimally. No missing constraint definitions or contributing terms
were skipped. Three template eliminations concerned unavailable wholesale demand response
devices. All 9,504 unmodelled dispatch rows, across 33 DUIDs, had zero published targets.

At the original worst Tasmania interval, 13:10 on 1 January, corrected ROP was 51.310184 AUD/MWh
against published ROP of 51.310180. Basslink flow was -180.85688 MW against -180.86122 MW.

Errors below are resolved ROP minus published NEMDE ROP. Percentiles and maxima are absolute
errors, in AUD/MWh. Each region has 288 observations.

| Region | Mean bias | Mean absolute error | Absolute p95 | Absolute p99 | Maximum absolute error | Within 1 AUD/MWh |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| NSW1 | +0.003865 | 0.051458 | 0.234166 | 1.404993 | 3.342100 | 97.9167% |
| QLD1 | +0.589810 | 0.646318 | 0.006686 | 7.983570 | 70.230000 | 96.5278% |
| VIC1 | +0.175233 | 0.233037 | 1.266324 | 4.739611 | 9.350000 | 93.7500% |
| SA1 | +0.295917 | 0.382648 | 1.621926 | 8.992979 | 15.436765 | 92.7083% |
| TAS1 | +0.135341 | 0.199202 | 0.400514 | 6.967366 | 9.637265 | 96.1806% |

Every region's median absolute error is below 0.0001 AUD/MWh. Queensland's three largest errors
account for 93.52% of its summed absolute error; South Australia has more frequent small errors.
These distributions should accompany aggregate means when assessing later changes.

Remaining discrepancies include PUMP1 at 06:20 and PUMP2 at 06:35 dispatching at 244 MW while
published targets are zero, consistent with missing fast-start profile treatment on this branch.
Snowtown non-conformance targets can exceed the hard UIGF bounds used here, whereas NEMDE's
separate violation priorities allow a different outcome. Loss-breakpoint pricing with fixed
integer indicators remains a separate formulation concern. Restoring missing inputs did not
establish complete NEMDE equivalence.

## 3. Compute time and the bottleneck

| Full-day phase | Time |
| --- | ---: |
| System construction | 102.06 s |
| Simulation/model construction | 153.74 s |
| Execution of 288 intervals | 3,655.15 s |
| Construction plus execution | 3,910.94 s, or 65.18 min |
| Mean execution per interval | 12.69 s |
| Mean including amortised construction | 13.58 s |
| Mean dispatch optimisation call | 8.72 s |
| Mean pricing/dual pass | 1.99 s |
| Peak resident memory | 5.14 GiB |

The dispatch optimisation and pricing wrappers together account for approximately 84% of
execution. Their times include wrapper work and should not be labelled entirely as native solver
CPU time. The old `solver_solve_time` field was NaN, so later experiments collected native logs
and explicit solve timings. Comparison/report generation is separate; the full-day comparison
phase took about 71.43 seconds. Package loading and compilation are not included in the
construction-plus-execution total above.

Interval event times varied substantially: median 8.30 s, p90 25.42 s and maximum 52.70 s.
Subsequent native logs showed that difficult HiGHS solves spent most of their MIP time in nested
heuristic subproblems. In the serial slow sample, 415 nested MIP calls consumed 213.06 of
237.12 seconds, or 89.9%. Each main MIP processed only one node. The bottleneck was therefore
repeated root/heuristic work rather than a large main branch-and-bound tree.

## 4. Acceleration scope and formulation questions

The replay uses each interval's published initial conditions. Its mathematical intervals can be
solved independently, even though the stock simulation executes them sequentially and may carry
solution hints between solves. This led to two distinct proposals, neither implemented here:

- Run independent replay chunks in separate processes, each owning its model, database connection
  and result store. Start with a small worker count because measured memory is substantial, and
  measure total throughput including repeated construction. Solver thread counts must be considered
  alongside process count.
- Build multiple independent intervals into one larger model to amortise update and transfer work.
  This requires an explicit independent-block formulation and correct per-interval inputs and
  pricing. Increasing the current horizon is not sufficient: it must not introduce lookahead or
  intertemporal ramping semantics. A larger MIP is not itself a guarantee of parallel execution.

The first concrete performance checks were native solver profiling and explicit HiGHS thread
settings, followed by heuristic effort, objective gaps and alternative solvers. Pricing
basis/presolve handling and model transfer overhead remain candidates for separate measurements.

The binary inventory for these samples is 715 variables: 714 padded
`InterconnectorLossSegmentFullVariable` entries (six interconnectors times 119 indicator slots)
and one Basslink `MNSPLinkDirectionVariable`. These are loss-ordering and directional-offer
variables, not generator unit-commitment decisions. Only 509-521 binaries survive initial
presolve in the HiGHS profiling sample. Original models have approximately 135,000 columns, but
initial presolve leaves approximately 8,700-12,200, so raw size alone is a poor predictor of solve
cost.

Strengthening the formulation means tightening the continuous relaxation while preserving all
valid integer solutions. A proposed concrete check is to export representative difficult models,
compare the initial relaxation bound with the final objective, inspect fractional loss indicators
and repeated heuristic work, and test valid bounds or alternative loss encodings on exactly the
same inputs. This dedicated reformulation experiment has not been performed. The existing
ordered-fill bounds already use segment widths; tightening must respect elastic constraints and
must not assume positive prices or force NEMDE's published dispatch.

Objective hints were discussed but not implemented. For minimisation, a complete feasible
incumbent provides an upper bound; a valid relaxation or solver proof provides a lower bound.
Published NEMDE prices are outputs, not a feasible dispatch or the model's objective value.
An arbitrary fraction such as 80% of an estimated objective does not establish a valid bound,
particularly with signed energy costs and large violation penalties. No NEMDE-price-based
objective cutoff or bound was introduced.

Explicit SOS2 loss interpolation was also scoped. A runtime probe found no native SOS2 support
in the installed HiGHS interface. The standard MOI SOS2-to-MILP bridge introduced 120 hidden
binaries for 121 weights, so merely declaring SOS2 would not remove the integer problem. A
logarithmic encoding could use seven binary decisions for 120 segments, but its performance and
relaxation strength have not been tested here. Bridge-generated binaries also require an audit of
PSI's integer-fixing pricing pass. No SOS2, logarithmic encoding, loss-curve coarsening or
production pricing-policy change was implemented.

## 5. HiGHS settings experiments

All performance probes use the fully populated cache and strict inputs. The sample is six easy
intervals, 04:05-04:30, and six difficult intervals, 17:20-17:45, on 1 January 2026 AEST. Fresh
processes warm the build and execution paths before measurement. These are single pilot runs,
not statistically established or full-day speedups. Each experiment has its own reference.

### Threads and heuristic effort

| Thread configuration | Execution for 12 intervals |
| --- | ---: |
| One, parallel off | 292.765 s |
| Two, parallel on | 252.231 s |
| Four, parallel on | 252.743 s |
| Automatic, parallel choose | 253.214 s |

Two and four threads differed from automatic by less than 0.4%; forcing one was slower. All
checked objectives and physical outputs agreed between profiles. There was no material basis to
change the production thread default.

A fresh automatic-thread baseline tested `mip_heuristic_effort` values 0.05, 0.01 and 0:
execution was respectively 248.141, 241.344 and 246.733 seconds. Outputs were unchanged. The best
observed reduction was 2.7%, insufficient evidence for a reliable default change. Zero effort did
not disable every heuristic; substantial nested-MIP work remained.

### Relative MIP gaps

The gap experiment retained absolute gap `1e-10` and reused its own zero-relative-gap reference.

| Relative gap | Execution, s | Construction plus execution, s | Max dispatch change, MW | Max regional price change, AUD/MWh |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 248.141 | 295.080 | 0 | 0 |
| 1e-8 | 235.267 | 284.242 | 0 | 0 |
| 1e-7 | 206.459 | 253.817 | 0.377228 | 4.14086 |
| 1e-6 | 80.561 | 128.440 | 18.8364 | 7.00175 |
| 1e-5 | 61.418 | 109.193 | 51.4611 | 15.0533 |
| 1e-4 | 61.053 | 108.068 | 77.8866 | 285.04 |

A small relative objective gap does not bound errors in dispatch or in prices from the separate
fixed-binary pricing LP. For example, gap `1e-7` changed the SA price at 04:15 by 4.14 AUD/MWh
while increasing the objective by only 0.130 units. Gap `1e-4` moved the TAS price at 04:05 from
65.12 to 350.16 AUD/MWh. The fastest tested setting with no checked output changes was `1e-8`,
a roughly 5% execution improvement on this sample. It remains a candidate for broader validation.
Production gaps remain zero relative and `1e-10` absolute.

Detailed methodology, native phase counts, output differences, NEMDE error tables and reproduction
commands are in [HiGHS replay profiling and threading probe](highs-performance.md).

## 6. SCIP, CBC and HiGHS comparison

Alternative solvers were installed in an isolated environment preserving the existing pinned
packages and PowerSimulations source. Repository Project and Manifest files were not changed.
Runtime engines were HiGHS 1.15.1, SCIP 10.0.3 and CBC 2.10.13.

This experiment has a fresh HiGHS reference, one requested solver thread, one BLAS thread, zero
relative gap, absolute gap `1e-10`, feasibility settings `1e-7` and a 180-second limit per solve.
A JuMP hook installs a fresh backend at each solve. All pricing LPs use HiGHS because the CBC
interface does not expose the needed constraint duals. Transfer and audit costs are included in
execution. These timings must not be ranked directly against the earlier gap/thread experiment.

| Dispatch solver | Execution for 12 intervals | Including system/model construction | Execution speedup versus this HiGHS reference |
| --- | ---: | ---: | ---: |
| HiGHS | 276.235 s | 324.244 s | 1.00x |
| SCIP, starts cleared | 128.822 s | 176.847 s | 2.14x |
| CBC | 115.084 s | 162.803 s | 2.40x |

CBC was slightly slower on the easy window; its overall gain came from the difficult window.
Both accepted alternative configurations matched HiGHS regional prices to floating-point
precision, with maximum dispatch differences of approximately 0.000002 MW. Their regional
NEMDE error statistics were consequently unchanged on this sample. This shows speed at preserved
sample accuracy, not removal of the full-day formulation discrepancies.

The first SCIP run retained prior-interval starts. Although it reported optimal status on all
12 dispatches, eight failed an independent consistency check: the fixed-binary pricing LP
materially improved the claimed MIP optimum. The largest improvement was approximately
236 million objective units. That run was rejected and retained as diagnostic evidence.

A two-interval replay reproduced the discrepancy. Computing the objective directly from returned
variable values agreed with SCIP's reported value. All three solvers then agreed on the exact
exported second-interval MPS model with starts omitted. Explicitly clearing starts before every
SCIP MIP produced an accepted 12-interval replay. HiGHS and CBC retained their supplied starts,
so this comparison discloses a start-policy difference. The cause within the start-enabled
solver/interface/replay path remains unresolved; this does not establish a general SCIP defect.
There is no automatic fallback or retry in the benchmark.

Every accepted dispatch and pricing solve passed status and feasibility checks, and all
36 dispatch/pricing objective pairs were consistent. The SCIP rerun additionally checked native
objectives against the original objective expressions. Ordered matrix hashes differed across
independent model constructions, so they were retained as diagnostics rather than used as proof
of identical arrays. The exported-MPS control establishes exact-model agreement for one interval.

Detailed results, caveats and reproduction are in
[SCIP, CBC and HiGHS on cached dispatch samples](solver-comparison.md).

## 7. Verification, delivery state and follow-up

The committed correctness work records passing root tests (1,604 assertions), Simulations tests
(2,958 assertions), final completeness regressions (15 assertions) and demand-setter tests
(477 assertions), plus Runic, Markdown lint and `git diff --check`. These are recorded session
results; no simulation or Julia test suite was rerun to write this note.

The performance work adds `benchmark_highs.jl`, `benchmark_solvers.jl`, and optional solver logging
and model-hook support in `measure_replicate_range.jl`. It records settings, solver logs, timings,
objectives, dispatch, energy/FCAS prices, interconnector outputs, coverage and validation results.
The solver handoff smoke checks cover MIP to pricing LP to MIP for all three solvers. Benchmark
Julia files were formatted with Runic and parsed, Markdown lint passed, and archived source/report
snapshots were checked against the worktree.

At the time of this note, `HEAD` and `origin/stock-simulation-v02` both resolve to `6a8015a`.
The later benchmark tooling, validation reports, changelog updates and this note are uncommitted.
The session's earlier commit-and-push request was completed for the correctness work; it does not
mean the subsequent experiments have been pushed. Production solver defaults, gap settings and
loss encoding remain unchanged by the performance experiments.

The next useful checks, in order, are:

1. Repeat CBC versus HiGHS over the complete trading day and additional difficult/negative-price
   periods, retaining strict inputs and zero relative gap. Measure end-to-end time and memory and
   validate prices, dispatch, losses and objective consistency.
2. Investigate the reproducible SCIP start-path failure before considering its production use.
3. Pilot a small number of independent replay processes and measure throughput including
   construction, memory and result collection. This remains separate from solver-internal threads.
4. Measure pricing LP basis/presolve and model-transfer overhead under controlled start policies.
5. Explore exact loss reformulations or valid bound tightening, including pricing compatibility.
   Treat nonzero gaps as an explicit accuracy tradeoff and batching as a separate model design.

### Evidence locations

All raw directories below are under `/run/media/simba/Store/aem_validation/stock_sim/`.

| Directory | Evidence |
| --- | --- |
| `nemde_compare/n288` | Original incomplete-input full-day comparison |
| `gap_analysis/` | Read-only discrepancy investigation and intermediate MNSP-restoration comparisons |
| `strict_inputs_20261017_v3` | Final 288-interval complete-input run, metrics, comparison and source patches |
| `highs_threads_20261017T122220` | Thread profiles, native logs and output checks |
| `highs_effort_20261017T134030` | Heuristic-effort experiment and fresh reference |
| `highs_gaps_20261017T151249` | Gap sweep, objective/output changes and NEMDE errors |
| `solver_compare_20261017T174946` | Accepted solver runs, rejected SCIP run, isolated environment and diagnostics |

The full-day run metadata names pre-commit `HEAD` `e4974f7`; its archived source patch contains
the changes subsequently committed as `6a8015a`. The performance reports identify `6a8015a` plus
their archived benchmark-only changes. Keeping those source patches and per-experiment references
is essential to interpreting the results.
