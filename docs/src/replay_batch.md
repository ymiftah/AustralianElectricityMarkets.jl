# [Batch replays and benchmark](@id replay-batch)

[Replaying NEMDE dispatch](@ref replay-nemde) replays a few intervals in one Julia session. For
days or months of intervals, the repository ships a batch runner and a report script in
`scripts/`. Both read the local cache and download nothing: populate the tables of
`table_requirements(NEMDEConfiguration())` for the period first. They run from the repository
root in the Simulations test environment.

## The batch runner

`scripts/replay_batch.jl` replays intervals against the published NEMDE outcome. A supervisor
process schedules trading days and runs each in a fresh worker process, which builds the
`System` with `nem_system`, the models with `nem_dispatch_sequence` and writes the comparisons
as CSV files under the run folder. `--output` names the run folder, which must not exist.

```sh
julia -O1 --project=AustralianElectricityMarketsSimulations/test scripts/replay_batch.jl --help
```

| Mode | Options | What is replayed |
| --- | --- | --- |
| Whole days | `--first DATE --last DATE --hours H --seed S` | Trading days of the period in a seeded random order, until `--hours` of wall time have elapsed; the day in progress is finished |
| One range | `--start DATETIME --intervals N` | `N` consecutive intervals from the interval ending at `--start`, within its trading day |
| Interval list | `--intervals-file PATH` | The intervals of a CSV with the header `interval`, each solved on its own |
| Random sample | `--sample N` | `N` distinct intervals drawn at random over `--first` to `--last` (seed `--seed`), each solved on its own |

Two switches change the model:

- `--closed-loop true` starts each interval after the first from the previous solve rather than
  from AEMO's observed state (`NEMClosedLoopDispatchProblem`). It needs consecutive intervals, so
  it is rejected with `--sample` and `--intervals-file`.
- `--fast-start false` solves one model per interval, without the fast-start inflexibility
  profiles. By default each interval runs NEMDE's commitment and dispatch runs when the
  `System` has a fast-start unit; see [Fast-start dispatch](@ref nemde-fast-start).

Each day folder holds the comparisons with the published outcome (`comparison_prices.csv`,
`comparison_dispatch.csv`, `comparison_interconnectors.csv`, `comparison_fcas_prices.csv`), a
`summary.csv` of paired errors, the skipped constraints and constraint violations, solver
statistics and phase timings. Energy prices compare the solved price with the published
regional original price (ROP). `scripts/README.md` lists every option, output file and timing
column.

## The report

`scripts/simulation_statistics.jl` summarises one or more saved runs without solving anything:
runtime breakdowns, error distributions by region, service, interconnector and unit, the
energy price tail and the largest errors.

```sh
julia --project=AustralianElectricityMarketsSimulations/test scripts/simulation_statistics.jl \
    RUN [RUN...] [--output FOLDER] [--hive FOLDER]
```

The report goes to `<first run>/simulation_statistics/` unless `--output` is given. With
`--hive`, dispatch errors are also grouped by each unit's region, dispatch type and schedule
type. Closed-loop and open-loop days are never pooled.

## The nempy benchmark

[nempy](https://github.com/UNSW-CEEM/nempy) publishes a benchmark of its own NEMDE replica over
1000 random dispatch intervals of July to December 2024. `benchmarking/nempy_2024h2_intervals.csv`
holds the same intervals, so the replay can be compared like for like, each interval solved
independently:

```sh
julia -O1 --project=AustralianElectricityMarketsSimulations/test scripts/replay_batch.jl \
    --intervals-file benchmarking/nempy_2024h2_intervals.csv \
    --hours 24 --output "$HOME/aem_validation/nempy-2024h2"
julia --project=AustralianElectricityMarketsSimulations/test scripts/simulation_statistics.jl \
    "$HOME/aem_validation/nempy-2024h2"
```

The report's `energy_price` section gives the signed error `ROP_solved - ROP_published`. nempy's
published energy price error over these intervals, in \$/MWh against the published ROP:

| Mean | Median | p5 | p95 |
| --- | --- | --- | --- |
| 0.13818 | 0.0 | -0.13336 | 0.01353 |

`benchmarking/README.md` describes how the intervals were drawn and the cache the run needs.
