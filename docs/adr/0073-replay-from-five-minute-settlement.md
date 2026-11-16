# 0073 Replay only from five-minute settlement

## Status

Accepted

## What

- Dispatch replays cover intervals from the 1 October 2021 trading day onwards. Readers and formulations are written against the five-minute-settlement tables only.
- `MNSP_PEROFFER` (30-minute availability, pre-5MS) keeps its table spec and stays populated but is never read; `read_mnsp_offers` reads `DISPATCH_MNSPBIDTRK`, `MNSP_DAYOFFER` and `MNSP_BIDOFFERPERIOD`.
- `populate_legacy_archive` stays: generic-constraint definitions effective before 2015 can still apply to intervals after 2021.

## How

- Nothing rejects an earlier `date_range`; such a replay has missing MNSP offers rather than an error.

## Why

- Supporting earlier intervals needs a 30-minute pre-settlement branch in every bid reader, not only for MNSP links.
