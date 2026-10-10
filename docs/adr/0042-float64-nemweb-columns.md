# 0042. Float64 for floating-point NEMWEB columns

## Status

Accepted

## Context

Every floating-point NEMWEB column was cached as `FLOAT` (Float32). Single precision rounds values
that the dispatch replication compares exactly: a floor bid of -1000 x MLF read back as -999.99999,
price ties are detected at 1e-6 $/MWh (below Float32 resolution at prices of order 1e3), and
merit-order comparisons between bands depend on the same digits.

## Decision

All floating-point entries in `COLUMN_TYPES` are `Float64`, written as `DOUBLE` in the parquet cache.
The `Float32 => "FLOAT"` entry stays in the type-name map so a caller can still request it.

## Consequences

- Every cached table must be re-populated with `populate(...; force_new = true)`. Partitions written
  earlier keep `FLOAT`; `union_by_name` reads mixed partitions back as `DOUBLE`, but the old values
  keep their Float32 rounding until re-populated.
- The parquet cache grows (DOUBLE columns are twice as wide before compression).
- Months that NEMWEB no longer serves cannot be re-populated and stay Float32.
