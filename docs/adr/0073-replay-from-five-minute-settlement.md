# 0073. Replay only from five-minute settlement

## Status

Accepted.

## Context

Five-minute settlement started on 1 October 2021. From that trading day, MNSP offers are read from
`DISPATCH_MNSPBIDTRK`, `MNSP_DAYOFFER` and `MNSP_BIDOFFERPERIOD`, with one availability row per
five-minute period. Earlier days hold availability per 30-minute period in `MNSP_PEROFFER`, which
`read_mnsp_offers` never read: a replay of an earlier interval had no MNSP offers. The table spec was
downloaded for nothing.

## Decision

- Dispatch replays cover intervals from the 1 October 2021 trading day onwards. Earlier intervals
  are out of scope, and readers and formulations are written against the five-minute-settlement
  tables only.
- The `MNSP_PEROFFER` table spec is removed.
- `populate_legacy_archive` stays: generic-constraint definitions effective before 2015 can still
  apply to intervals after 2021.

## Consequences

- Supporting earlier intervals would need a pre-settlement branch in every bid reader (30-minute
  periods), not only for MNSP links.
- Nothing rejects an earlier `date_range` explicitly; such a replay has missing MNSP offers rather
  than an error.
