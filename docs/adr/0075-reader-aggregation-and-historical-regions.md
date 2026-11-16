# 0075 SQL aggregation and historical region snapshots

## Status

Accepted

## What

- Regions come from the latest cached `DISPATCHREGIONSUM` timestamp at or before `as_of` (latest overall without `as_of`); no eligible snapshot throws. The snapshot must contain all regions, since absence from an incomplete one cannot be told from retirement.
- Buses and links are built from the same resolved interconnectors. A timestamp after the last cached snapshot uses that snapshot; no future snapshot is substituted for missing earlier history.
- Interconnector loss readers take `as_of` as a keyword; positional forms remain as deprecated forwarders.
- Demand aggregation and joined bid preparation run in DuckDB, matching Julia's `ceil(DateTime, resolution)` buckets with half-open output ranges and the means of nonmissing values (`NaN` for an all-missing bucket). Bid bands keep numeric price/availability order and group by trading day, DUID, direction, bid type and ceiled interval.
- `read_energy_bids` aggregates by maximum; `read_bids` by mean. Keep them distinct.

## Why

- Region snapshot selection and aggregation onto coarser periods are project policies, not AEMO rules; no bound, constraint or cost term changes.
- Sources: AEMO Electricity Data Model Report 5.7.0, `DISPATCHREGIONSUM` pp. 283-291, `BIDDAYOFFER_D` pp. 58-60, `BIDPEROFFER_D` pp. 65-67.
