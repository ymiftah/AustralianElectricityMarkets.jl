# Interval benchmark against nempy

`nempy_2024h2_intervals.csv` holds the 1000 dispatch intervals of nempy's benchmark
(`get_test_intervals(number=1000)` in
[UNSW-CEEM/nempy `benchmarking`](https://github.com/UNSW-CEEM/nempy/tree/master/benchmarking)):
`random.seed(1)`, then `random.sample(range(1, n), 1000)` over the five-minute grid from
2024-07-01 00:00 to 2025-01-01 00:00. Running the same intervals, each solved independently,
allows a like-for-like comparison of the energy price error against NEMDE.

The timestamps are interval-ending `SETTLEMENTDATE` values in AEST (UTC+10), sorted, with the
header `interval`. An interval ending 00:05 through 04:00 belongs to the previous trading day.

## One-command run

`scripts/nempy_benchmark.jl` does everything below (optional cache population, the 1000 independent solves, the
statistics report) and writes analysis-ready files to `<output>/analysis/`: `price_errors.csv`,
`interval_runtimes.csv`, `fcas_errors.csv`, `dispatch_errors.csv`, `interconnector_errors.csv`,
`nempy_comparison.md` and `manifest.toml`. The per-day folders keep all raw files.

```sh
julia -O1 --project=AustralianElectricityMarketsSimulations/test scripts/nempy_benchmark.jl \
    --populate true --hours 24 --output "$HOME/aem_validation/nempy-2024h2"
```

## Populate the cache

The run reads the local cache and downloads nothing, so populate July to December 2024 first.
The tables are those of `table_requirements(NEMDEConfiguration())`. `DISPATCH_FCAS_REQ` covers the
months before 2025-06, and `DISPATCH_FCAS_REQ_CONSTRAINT` only applies from 2025-06, so skip it here.

```julia
using AustralianElectricityMarkets
using AustralianElectricityMarketsData: populate
using Dates

db = aem_connect()
tables = filter(!=(:DISPATCH_FCAS_REQ_CONSTRAINT), table_requirements(NEMDEConfiguration()))
for table in tables
    populate(db, table, Date(2024, 6, 30), Date(2024, 12, 31))
end
```

The range starts on 2024-06-30 because the first intervals of 2024-07-01 (00:05 to 04:00) belong to
that trading day. `populate` is idempotent and skips months already cached.

## Run

From the repository root, using the Simulations test environment. Each trading day is one worker
that builds one system and solves its selected intervals one by one, so `--hours` bounds the run
(days run in a seeded random order). The run folder must not exist.

```sh
julia -O1 --project=AustralianElectricityMarketsSimulations/test scripts/batch_run.jl \
    --intervals-file benchmarking/nempy_2024h2_intervals.csv \
    --hours 24 --output "$HOME/aem_validation/nempy-2024h2"
```

Then report it:

```sh
julia --project=AustralianElectricityMarketsSimulations/test scripts/simulation_statistics.jl \
    "$HOME/aem_validation/nempy-2024h2"
```

The energy price error is the signed `ROP_solved - ROP_published` of `comparison_prices.csv`,
summarised under `energy_price` in the report.

## nempy's published result

Energy price error against the published `ROP` over these 1000 intervals, from nempy's
`benchmarking/bidirectional_units.py`:

| Mean | Median | p5 | p95 |
| --- | --- | --- | --- |
| 0.13818 | 0.0 | -0.13336 | 0.01353 |

AEMSim's solved price is compared with the unadjusted `ROP`, as nempy's is.
