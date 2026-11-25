# 0042 Float64 for floating-point NEMWEB columns

## Status

Accepted

## What

- Every floating-point entry in `COLUMN_TYPES` is `Float64`, written as `DOUBLE` in the parquet cache.

## How

- The `Float32 => "FLOAT"` entry stays in the type-name map in `nemweb_load/parquet.jl` so a caller can still request it.
- After changing column types, re-populate with `populate(...; force_new = true)`. Old partitions keep Float32-rounded values even though `union_by_name` reads them back as `DOUBLE`; months NEMWEB no longer serves cannot be re-populated.

## Why

- NEMDE compares values exactly: a floor bid of -1000 x MLF read back as -999.99999 under Float32, price ties are detected at 1e-6 $/MWh (below Float32 resolution at prices near 1e3), and merit-order comparisons between bands depend on the same digits.
