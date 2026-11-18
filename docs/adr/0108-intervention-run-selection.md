# 0108 Intervention run selection per interval

## Status

Accepted. Amends the intervention sentence of [0027](0027-loss-equation-regional-demand.md).

## What

- `intervention = 0` (default) is the pricing run: `COALESCE(INTERVENTION, 0) = 0`, as before.
- `intervention = 1` is the physical run, chosen per `SETTLEMENTDATE`: the `INTERVENTION = 1` rows if the interval has any, else the `INTERVENTION = 0` rows. An interval never mixes runs.
- Applies to DISPATCHLOAD, DISPATCHREGIONSUM, DISPATCHPRICE, DISPATCHINTERCONNECTORRES, DISPATCHCONSTRAINT and DISPATCH_FCAS_REQ. Each table decides its run on its own.
- DISPATCH_FCAS_REQ_CONSTRAINT has no run column and publishes one run per key, so `intervention` does not filter it.
- `read_published_interval(...; intervention = 1)`: dispatch (`TOTALCLEARED`) and interconnector flows follow the selected run; energy and FCAS prices stay on run 0.
- A table without an `INTERVENTION` column is read unfiltered.
- Any other `intervention` value throws an `ArgumentError`.

## How

- `_run_rows` in `src/readers/query_helpers.jl` returns the source subquery. Run 0 keeps the `COALESCE(INTERVENTION, 0) = ?` predicate with 0 bound. Run 1 keeps the rows where `COALESCE(INTERVENTION, 0) = max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE)`.
- The window sits in a subquery bounded by the reader's date predicate and before the caller's own predicates, so a unit filter (the semi-scheduled UIGF rows) cannot change an interval's run.
- `read_demand` decides the run separately for DISPATCHREGIONSUM and for the charging DISPATCHLOAD rows.

## Why

- AEMO's Intervention Pricing Methodology, section 3.3: the base case target run flagged `Intervention = 1` sets the dispatch targets, and the pricing run `Intervention = 0` sets prices. With no intervention only run 0 exists, so the per-interval fallback reads the same rows as the pricing run.
- An exact match on 1 returned no rows for intervals without an intervention, leaving gaps in the physical series.
- Prices come from run 0 because AEMO sets them there.
- Empirical caveat: the local cache holds run 1 only in DISPATCHCONSTRAINT, for 2015 to 2020. The other five tables hold run 0 only, for 2025 to 2026. Run 1 behaviour is tested on fixtures, not on real data.
- DISPATCH_FCAS_REQ_CONSTRAINT carries no run column, so its rows are read as published.
