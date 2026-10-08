# 0043. Dispatch comparison script: market-day sampling and nempy as an optional subprocess

## Status

Accepted

## Context

Comparing AEMSim with NEMDE and stock nempy needs NEMDE case-file XMLs, which NEMWEB serves as one
zip of about 170 MB per market day (04:05 to 04:00). A uniform draw of 100 intervals from a month
touches nearly every day, so about 5 GB would be downloaded to extract a few hundred kilobytes.
nempy needs a Python environment (mip with CBC, pandas, nempy at commit 2d3cef0) that the Julia
environments do not have.

## Decision

- **Sampling unit is the market day.** `comparison_sample` first draws `--days K` market days
  (default `min(N, 10)`), then N intervals uniformly without replacement from those days. The
  download is bounded by K zips whatever N is. The draw is a seeded hash ordering, not `Random`, so
  it is stable across Julia versions. Dates in `--from`/`--to`/`--range` are market days, so a day
  is exactly one zip.
- **nempy is a subprocess, and optional.** The script calls the Python files in
  `scripts/nempy/` with a configurable interpreter and reads the CSVs they write. When nempy is not
  importable it prints a message and compares AEMSim with NEMDE only.
- **Resumable.** AEMSim rows are appended per interval to `aemsim_long.csv` and `aemsim_status.csv`;
  nempy skips intervals with a `done` marker. Failures are recorded, not raised.
- **The script lives next to `validate_month.jl`** in `AustralianElectricityMarketsSimulations/scripts/`,
  the repository's script location, and the testable logic in `src/replication/comparison.jl`.

## Consequences

- A sample of 100 intervals from 10 days downloads about 1.7 GB once; reuse `--nempy-dir` to share
  the XML cache between runs.
- The sample is clustered by day, so day-level effects (a binding constraint all day) weigh more
  than in a uniform draw.
- nempy takes AEMO's solved constraint RHS and `INITIALMW` as inputs (as AEMSim does), and the MMS
  tables come from the same hive cache; its agreement with NEMDE carries that input advantage.
