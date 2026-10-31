# 0075. SQL aggregation and historical region snapshots

## Status

Accepted.

## Context

Region selection used every region ever present in cached demand, and bus construction resolved
interconnectors separately without `as_of`. Demand aggregation and joined bid preparation loaded
raw rows into DataFrames before bucketing, grouping and joining them.

## Decision

- Resolve regions from the latest cached `DISPATCHREGIONSUM` timestamp at or before `as_of`;
  without `as_of`, use the latest cached timestamp. Throw when no eligible snapshot exists.
  This is a cache-selection policy, not an AEMO rule. The selected snapshot must contain all regions;
  absence from an incomplete snapshot cannot be distinguished from retirement.
- Build buses and links from the same resolved interconnectors. A timestamp after the last cached
  demand snapshot uses that snapshot; no future snapshot is substituted for missing earlier history.
- Use required `as_of` keywords on the loss readers and retain deprecated positional forwarding methods.
- Aggregate demand and prepare joined bids in DuckDB. Match Julia's `ceil(DateTime, resolution)`
  epochs, preserve exact boundaries, and retain half-open output ranges. Keep the existing means of
  nonmissing quantities, including `NaN` for an all-missing aggregate, and preserve price/availability
  band order numerically. Group bids by trading day, DUID, direction, bid type and ceiled interval.
- Keep the maximum aggregation of `read_energy_bids` distinct from the mean in `read_bids`.

## Sources

AEMO Electricity Data Model Report 5.7.0 (23 April 2026), `DISPATCHREGIONSUM` pp. 283-291,
`BIDDAYOFFER_D` pp. 58-60 and `BIDPEROFFER_D` pp. 65-67 define the interval, region, direction,
trading-day and numbered-band fields. Regional snapshot selection and aggregation onto coarser
study periods are project policies; no dispatch bounds, constraints or objective terms change.

## Validation

Generated local parquet fixtures cover historical region retirement, missing earlier snapshots,
keyword/positional equivalence, Julia/SQL bucket alignment, null means, charging-demand terms,
raw and aggregated bid directions, numerical band ordering and unmatched price offers. No test
contacts external systems.
