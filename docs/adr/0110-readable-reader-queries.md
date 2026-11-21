# 0110 Readers are readable queries

## Status

Accepted. Amends the "How" section of [0108](0108-intervention-run-selection.md) and its
no-`INTERVENTION`-column rule.

## What

- Each public `read_*` that returns a `DataFrame` writes its query out: literal `SELECT` / `FROM` /
  `WHERE` / `QUALIFY` text, `?` parameters listed in placeholder order in one vector.
- Only values are interpolated: a `read_hive` source, a `_ceil_timestamp_sql` bucket expression, a
  `_bid_type_list` list, an explicit band column list, or a literal timestamp bound. No helper returns
  clauses, CTEs or `(sql, params)` pairs.
- Julia-side work on the result uses the DataFrames.jl API (`subset`, `transform!`, `groupby` /
  `combine`, `leftjoin!`), with `@chain` for several steps.
- No branching on keyword combinations or on the cached schema. The remaining branches are guards
  (`_require_cached`, `_require_columns`, `_check_intervention`) and the `DISPATCH_FCAS_REQ` /
  `DISPATCH_FCAS_REQ_CONSTRAINT` switch.
- Run selection is a `run` CTE with the run bound as a parameter:
  `QUALIFY COALESCE(INTERVENTION, 0) = CASE WHEN ? = 0 THEN 0 ELSE max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE) END`,
  followed by the archive-month dedup in the next step.
- `read_units`, `read_loss_factors`, `read_interconnectors` and `read_demand` take a positional
  `date_range`; `nem_network` and the regional `nem_system` take a required `date_range` keyword.
  The unit and loss-factor window ends at the last interval of the half-open range,
  `last(date_range) - Minute(5)`. The `as_of` / `through` / latest-cached forms are gone.
- The point-in-time readers (`read_interconnector_loss_*`, `read_mnsp_links`) keep their `as_of`:
  `src/system/mnsp.jl` resolves loss parameters at the last interval as well as the first.

## How

- `_read_dispatch_table`, `_run_rows`, `_cast_double`, `_price_columns`, `_price_block`,
  `_period_offers_sql`, `_read_period_offers`, `_fcas_req_union_sql`, `_registration_window_sql` and
  `_current_regions` are removed; each reader inlines what it used.
- FCAS prices and FCAS dispatch are unpivoted in DuckDB (`UNPIVOT INCLUDE NULLS`), replacing the
  per-market append loops.
- `_massage_bids` builds its whole output in one query. At a coarse resolution each bucket carries
  the period columns (the FCAS trapezium) of its last interval with `arg_max_null`, replacing the
  second read and `innerjoin` of `read_fcas_bids`.
- The `in_force` fast-start lookup is a separate fixed ASOF query over the distinct offer keys,
  applied with `leftjoin!` / `transform!`.

## Why

- Readability of each query outweighs reuse: the helper stack hid what each reader ran, and the
  keyword branches multiplied the query shapes to test.
- Cost: version resolution and run selection SQL repeat from reader to reader.
- Caches predating `INTERVENTION`, `APCFLAG` or the FCAS price and availability columns are no
  longer supported; a column absent from every partition fails the query. Repopulate with
  `force_new = true`. Real NEMWEB caches from 2024 on carry every column read.
- Every system build already has a date range, so the latest-cached forms only served ad hoc reads.
- Checked on the real cache (2026-03-10 and 2025-01-15, six hours, native and 30-minute
  resolution, both runs): every reader returns the same rows as before; some now come sorted where
  they were unordered.
