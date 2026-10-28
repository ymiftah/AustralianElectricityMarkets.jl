# Historical NEM dispatch replays

These scripts build systems from the local NEMWEB cache, solve five-minute dispatch
replicas, and compare them with AEMO's published NEMDE outcomes. Run commands from
the repository root, using the Simulations test environment and the installed Julia
workspace runtime:

```sh
julia -O1 --project=AustralianElectricityMarketsSimulations/test scripts/replicate_random_days.jl --help
```

## Detailed statistics from saved runs

Use Python 3.11 or newer to report saved outputs without starting Julia or
running another simulation. No additional Python packages are required:

```sh
python3 scripts/simulation_statistics.py \
    /run/media/simba/Store/aem_validation/overnight_10h_20261027T120955Z \
    /run/media/simba/Store/aem_validation/overnight_10h_parallel_20261027T131045Z
```

The default report folder is `<first run>/simulation_statistics/`. Set
`--output /path/to/report` to choose another folder. Re-running the command
refreshes only the generated report files. Source logs and comparisons are read
without alteration; running jobs, dependency settings and solver settings are
not changed. Active runs are supported: incomplete trailing CSV records are
ignored with warnings, and failed/in-progress timing prefixes remain visible.

The report includes:

| File | Contents |
| --- | --- |
| `report.md` | Runtime breakdown, timing percentiles, NEMDE errors, regional prices, unit outliers, memory and failures |
| `statistics.json` | Full report, provenance, status, warnings and coverage |
| `runtime.csv` | Per-day totals, updates, MIP, pricing, auxiliary work, writes, state and residual time |
| `timing_percentiles.csv` | Call counts, totals, min/mean, p5/p25/p50/p75/p90/p95/p99/max by phase and update cohort |
| `errors.csv` | Per-day absolute-error percentiles, signed bias, MAE, RMSE, missing rows and duplicates |
| `entity_errors.csv` | The same distributions by DUID, region, FCAS region/service and interconnector, with paired-interval coverage |
| `worst_errors.csv` | Largest comparison errors and their interval/entity/published/solved values |
| `slowest_intervals.csv` | Slowest update, MIP, pricing and write calls per day |
| `memory_statistics.csv` | Sampled worker RSS distributions and recorded high-water RSS, in MiB |
| `native_timers.csv` | Native timer snapshots with their hierarchy and call counts; nested totals overlap |
| `phase_boundaries.csv` | Loading, preflight, build, execution, comparison and export boundaries with observed phase spans |

Energy comparisons use **ROP against ROP**, not RRP. Percentiles use linear
interpolation; unqualified error percentiles describe absolute errors. Signed
bias and signed p5/p95 are included. Missing values are never replaced with zero.
Every duplicated comparison key is excluded, rather than choosing an arbitrary
copy. Regional/FCAS expected groups stay visible even when no values are paired.
Dispatch/interconnector inventories are inferred from exported rows.

Accuracy reports use completed days only. Pooled errors retain the first
completed attempt of each trading day in argument order, exclude overlaps and
exclude attempts with different recorded provenance. Each day's own results
remain available. Different seeds do not guarantee disjoint trading days.
Independent numerical-feasibility audit coverage is not established by this
script, even when the source solver reports `OPTIMAL`.

Timing distinguishes the solve wrapper from its nested MIP/pricing/auxiliary
timers. Compilation and GC are already included in measured wall times, and
cover instrumented calls only. Allocation totals describe allocation traffic,
not retained memory. Unattributed execution includes state work when native
state timings are unavailable. Ambiguous cumulative native snapshots are not
summed. Observed phase spans include framework overhead and overlap internal
timers. Summed parallel worker time is not elapsed host wall time.

The default `--cache-windows 24` only labels likely refill boundaries. Set it to
the input-cache window count used by the source run; it does not change a run's
cache. The labels identify a timing pattern, not a measured attribution to IO.

Run the Python-only regression tests with:

```sh
python3 -m unittest discover -s test/scripts -p 'test_simulation_statistics.py'
```

## Overnight: random trading days for ten hours

The default command shuffles all 181 trading days from **2026-01-01 through
2026-06-30**, without replacement, and starts days until ten hours have elapsed.
It finishes the day already in progress, including exports and comparison, even
if that takes the run past ten hours. It stops earlier if every day is attempted.
The budget includes worker startup, package loading, compilation, system and model
construction, execution, comparisons and exports. It is checked between days;
there is no solver time limit.

```sh
julia -O1 --project=AustralianElectricityMarketsSimulations/test scripts/replicate_random_days.jl
```

The examples use `-O1` for Julia code optimisation. Each trading day runs in a
fresh Julia process, so package loading and first-use compilation recur per day.
This bounds native HDF5 and solver resource lifetimes. The supervisor checks one
monotonic admission deadline and never kills the final admitted day at that deadline.

Default outputs go to a new timestamped subfolder of
`/run/media/simba/Store/aem_validation/`, for example
`/run/media/simba/Store/aem_validation/20261026T100000Z_12345/`.
The timestamp is UTC. The script prints the actual folder on launch.
Use `--output` to specify the exact run folder; it must not already exist.

For an unattended run that survives closing the terminal:

```sh
mkdir -p scripts/results
nohup julia -O1 --project=AustralianElectricityMarketsSimulations/test \
    scripts/replicate_random_days.jl \
    > scripts/results/overnight-launch.log 2>&1 < /dev/null &
echo $! > scripts/results/overnight.pid
tail -f scripts/results/overnight-launch.log
```

The launch log shows the output folder, current phase and memory samples. The
supervisor writes the worker's detailed output to `<run folder>/run.log`.
The machine must remain awake and the Store drive mounted during the run.

An explicit configuration equivalent to the defaults:

```sh
julia -O1 --project=AustralianElectricityMarketsSimulations/test \
    scripts/replicate_random_days.jl \
    --first 2026-01-01 --last 2026-06-30 --hours 10 --seed 20261026 \
    --hive "$HOME/.nemdb_cache" \
    --output /run/media/simba/Store/aem_validation/overnight-2026-01-to-06 \
    --sample-seconds 5 --solver-threads 1 --cache-size-mib 64
```

`--time-series-in-memory true` holds the time series in memory (default `false`, on disk), which cuts
per-step parameter updates but raises peak memory.

The seed fixes the shuffled order for the same Julia version. Change `--seed` for
a different order. Failed days are recorded and skipped, with no automatic retry.
If no day completes, the command exits with an error. A run with some failures
retains its successful days and records both counts in `outcome.toml`.

### Solver and system defaults

The workspace temporarily pins forks of InfrastructureSystems 3.6.3
([`121d433`](https://github.com/ymiftah/InfrastructureSystems.jl/commit/121d4331f4abc4274fc64c179e912daf10d63607),
which limits the forecast cache's initial sizing read to one forecast window),
PowerSimulations 0.38.5
([`b5e8775`](https://github.com/ymiftah/PowerSimulations.jl/commit/b5e8775f3f9d18f133f913d3561860d1d39f6c64))
and PowerSystems 5.12.4
([`03f9639`](https://github.com/ymiftah/PowerSystems.jl/commit/03f9639648cc01c62df26836bdc620f2382521ff)).
After updating the checkout, compare `Pkg.status` with these revisions. A root
`Pkg.resolve()` applies root source pins only; for a stale subproject pin, run
`Pkg.add(url = ..., rev = ...)` with that project active. Existing frozen replay
launches retain their own dependency versions.

- HiGHS with `mip_rel_gap = 1e-8` and `mip_abs_gap = 1e-10`.
- One solver thread, all `REPLICATION_PARTS`, and `intervention = 0` (pricing run).
- A new system and model per trading day, with interval parameters updated in
  place within the day. The existing workflow also splits at 00:05 on July 1.
- Historical metered `INITIALMW` at each interval, rather than the previous
  replica's dispatch target.
- File-backed system time series and a 64 MiB PSI results write cache, limiting
  memory retained for time series and buffered results. Each worker exits
  after its day; PID-tagged memory samples cover loading through export.

Each selected trading day contains **288 interval-ending timestamps**, from
04:05 AEST on that date through 04:00 AEST the following date. Market timestamps
use fixed AEST (UTC+10), including during daylight saving in Melbourne.
The June 30 trading day therefore includes July 1 intervals, and both of its
financial-year chunks finish before the next budget check.

### Required cached inputs

The scripts read existing local parquet data and do not download missing inputs.
The cache must contain all tables used by `NEMDEConfiguration`, including
`DISPATCHINTERCONNECTORRES`, plus the published dispatch and price tables used
by `read_published_interval`. The half-open input range ends ten minutes after
the final solved interval, so its five-minute input grid includes the following
interval. To include June 30, retain July 1 inputs through 04:05 AEST,
as well as the applicable July 1 static definitions, bids and penalty settings.
Historical/as-of tables may require earlier effective records.

The selected day order is saved before any model is built. A missing partition,
incomplete interval coverage, failed pre-flight check or solve failure appears
in `failures.csv` and the day's `error.txt`, with partial PSI files retained.
Check these files in the morning even if the command exits successfully.

## Outputs and monitoring

Set `run` to the folder printed at launch:

```sh
run=/run/media/simba/Store/aem_validation/20261026T100000Z_12345
tail -f "$run/run.log"
```

In another terminal:

```sh
watch -n 10 "cat '$run/status.toml'; tail -n 3 '$run/memory.csv'; tail -n 3 '$run/days.csv'"
```

Some files appear only after the first day finishes. CSVs and status files are
flushed as they are written; successfully exported days survive later failures.

| File | Contents |
| --- | --- |
| `run.toml` | Options, Julia version, Git revision, start time and solver gaps |
| `scheduled_days.csv` | Full shuffled order, with each day's first and last interval |
| `status.toml` | Current trading day and phase; completion/failure counts at the end |
| `phases.csv` | UTC time and elapsed seconds at preflight, system build, model build, execution, comparison and export boundaries |
| `memory.csv` | Periodic worker RSS, lifetime peak RSS, virtual memory and available host memory, in MiB |
| `days.csv` | One row per successfully exported day, with interval count and timing totals |
| `failures.csv` | One row per failed day, elapsed time and exception; created only on failure |
| `outcome.toml` | Final completed/failed counts, elapsed time and stopping reason |
| `run.log` | Detailed worker and PSI output |
| `YYYY-MM-DD/` | Day's comparison CSVs, timings, violations and native PSI result stores |

`memory.csv` is sampled by the parent process, independently of the Julia worker,
so samples continue during native HiGHS calls. It includes worker package loading,
builds, parameter updates, solves, comparisons and exports. Each day has a fresh
worker PID; no worker is sampled between days.
It requires Linux `/proc`. RSS covers the worker's native allocations, including
DuckDB and HiGHS; it does not include the lightweight supervisor or filesystem
page cache. Peak RSS is the worker's lifetime high-water mark, covering its single trading day.
Sampling is periodic rather than a guarantee of observing every transient peak.

Timing columns in `days.csv`:

| Column | Measurement in seconds |
| --- | --- |
| `system_build_s` | System construction and `prepare_replication!` |
| `model_build_s` | Simulation/model construction, pre-flight checks and `PSI.build!` |
| `execute_s` | Complete execution loop, including updates, solves, dual calculation and result writes |
| `solver_s` | Sum of solver-reported solve times |
| `timed_solve_s` | Sum of PSI's measured solve times |
| `dual_calculation_s` | Sum of PSI's dual-calculation times |
| `compare_s` | Result extraction and reading/joining published outcomes |
| `elapsed_s` | Whole day, including CSV exports |

First-use compilation is included in the phase where it happens. Daily elapsed
time includes worker startup and package loading; supervisor setup and between-day
overhead explain the remainder in overall run wall time. The fields describe overlapping measurements: do not add
`execute_s`, `solver_s`, `timed_solve_s` and `dual_calculation_s` together.
Daily timing totals become available when a day finishes. While it is running,
use `status.toml`, `phases.csv`, memory samples and the native PSI logs.

Each day folder contains:

- `chunks.csv`: chunk boundaries, output folders and build/execute/compare times.
- `solver_stats.csv`: per-interval objective, solver solve time, measured solve
  time, dual-calculation time and termination status.
- `comparison_prices.csv`: solved `ROP` against published `ROP` and `RRP`.
- `comparison_dispatch.csv`: solved and published `TOTALCLEARED` by DUID.
- `comparison_interconnectors.csv`: solved and published `MWFLOW` and `MWLOSSES`.
- `comparison_fcas_prices.csv`: solved and published FCAS `ROP` by region/service.
- `summary.csv`: paired-row MAE, RMSE, maximum absolute error and signed bias for
  energy prices, dispatch MW, interconnector flows/losses and FCAS prices, with
  missing and non-finite row counts reported separately.
- `skipped_constraints.csv`, `constraint_violations.csv`, `ramp_violations.csv`.
- `chunk_1/` (and `chunk_2/` at the financial-year boundary): native PSI simulation
  folders, logs, `simulation_store.h5` and file-backed system time series.

Prices are in $/MWh and power quantities are in MW. Compare solved prices with
published **ROP**, the unadjusted dispatch price; published RRP can differ under
administered pricing. CSV comparison tables retain published rows without a
solved counterpart as empty cells. Missing rows do not count as zero error.
The summary covers the published keys retained by the existing replay workflow;
it is a diagnostic, not a claim that the replica exactly matches NEMDE.

## Consecutive days or selected intervals

For consecutive days, use the existing `ReplayWorkflow.replicate_range` function.
This example solves two full trading days and retains native PSI outputs:

```julia
using AustralianElectricityMarkets, AustralianElectricityMarketsSimulations
using Dates, HiGHS
using PowerSimulations: optimizer_with_attributes

include("scripts/replay_workflow.jl")
using .ReplayWorkflow: replicate_range

db = aem_connect(HiveConfiguration(hive_location = joinpath(homedir(), ".nemdb_cache")))
optimizer = optimizer_with_attributes(
    HiGHS.Optimizer, "mip_rel_gap" => 1e-8, "mip_abs_gap" => 1e-10,
    "threads" => 1, "output_flag" => false,
)
result = replicate_range(
    db, DateTime(2026, 1, 1, 4, 5), DateTime(2026, 1, 3, 4, 0);
    optimizer, output_dir = "/run/media/simba/Store/aem_validation/consecutive-days",
    time_series_in_memory = false, cache_size_mib = 64,
)
result.comparison.dispatch
result.solver_stats
result.chunks
```

`replicate_range` returns comparison tables in memory and writes native PSI
stores to `output_dir`; the overnight wrapper additionally exports CSVs and
resource samples. Consecutive-range execution has no ten-hour budget.

For a short terminal comparison using the older positional CLI:

```sh
julia -O1 --project=AustralianElectricityMarketsSimulations/test scripts/replicate_range.jl \
    2026-01-01T04:05:00 2026-01-01T04:15:00 "$HOME/.nemdb_cache"
```

That older CLI prints comparisons, uses its existing zero-relative-gap default,
and stores PSI outputs in temporary folders. Use the overnight runner when you
need the persistent outputs and `1e-8` relative gap described above.

## HDF5 dependency

The environment requires HDF5 0.17.5 and pins its official fixed release-branch revision
until that version is tagged. It contains the datatype-handle cleanup needed to prevent
construction overhead growing across repeated builds. Instantiate the checked-out project
before launching; keep the project source pins when reproducing a run. The worker snapshots
its resolved manifest and package sources.

## Early validation and detailed timing

Before constructing each chunk, a data-only preflight checks the padded five-minute
range, including the interval after the trading day used by forecast preparation.
It verifies both MNSP directional links against the exact offers joined by the
existing reader, and checks exact invoked generic-constraint definition versions.
Known built-in zero-flow constraints and participant fixed-load rows retain their
existing handling. Model-level input checks still run. No data is downloaded and
failed days are retained without retrying. Keep the checkout unchanged during a batch
so code cannot change while a worker loads it.

`phases.csv` separates preflight, system/preprocessing, model build, execution,
comparison and export. Each day's provenance, `runner_source/` and `package_source/` snapshots identify
the scripts, package sources, actual worker revision and dirty checkout state.

Per-model `interval_timings.csv` is derived after `execute!` from PSI's native
records, without wrapping any PSI method. Each executed step writes two rows, a
`parameter_update` row and a `solve_and_write` row. The step's `ProblemExecutionEvent`
start opens the `parameter_update` span, which ends at the last `ParameterUpdateEvent`
or `InitialConditionUpdateEvent` logged for that step's simulation time (zero when the
step logs none, as for the first step of a chunk). The `solve_and_write` span runs
from there to the step's `ProblemExecutionEvent` done. Solver fields come from
`PSI.read_optimizer_stats`. Schema version 2 is in the `schema_version` column.

Schema 2 changes the meaning of these fields:

- `phase`: `solve_impl` and `result_write` are replaced by `solve_and_write`, which
  covers the solve, pricing, auxiliary calculation and result write.
- `wall_s`: the `parameter_update` wall now starts at the step's execution start,
  so it includes any time before the first logged update.
- `allocated_bytes`, `gc_s`: on `solve_and_write` rows these are the allocation and GC
  time of the optimizer call itself (`solve_bytes_alloc`, `sec_in_gc`), not of the
  whole phase.
- `timed_solve_s`, `pricing_s`, `auxiliary_s`: on `solve_and_write` rows, the optimizer's
  own timers for the solve, dual and auxiliary calculations, unchanged in meaning.
- `execution_count`: the zero-based step index within the chunk, as before.
- `timestamp_utc`: the end of the phase, converted from the recorder's local clock with
  the offset at write time.

Unavailable in schema 2 and written as `NaN`: `compilation_s` on every row, and
`allocated_bytes`, `gc_s` and the solver fields on `parameter_update` rows. Native
`timers_build_chunk_*.toml` and `timers_execute_chunk_*.toml` retain the nested PSI
timing tree. MIP, pricing and auxiliary solve times are nested in the solve span; do
not sum both. Native state updates are in execution timers. Memory samples include
PID and both sampled RSS and the worker's high-water RSS. Add the unmeasured residual
to reconcile phase totals with overall wall time; compilation/GC measurements are not
whole-run coverage.
