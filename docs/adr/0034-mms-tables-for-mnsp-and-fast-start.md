# 0034 MMS tables for MNSP offers and fast-start state

## Status

Accepted. Fast-start state derivation is extended by [0106](0106-fast-start-two-run-dispatch.md).

## What

- MNSP offers and the fast-start starting state are read from MMSDM five-minute tables (AEMO MMS Data Model v5.7.0 and the fast-start inflexibility profile procedure).

## How

- MNSP offers: `MNSP_DAYOFFER` (price bands), `MNSP_BIDOFFERPERIOD` (`MAXAVAIL`, `FIXEDLOAD`, `RAMPUPRATE`, `BANDAVAIL1-10` per `PERIODID`) and `DISPATCH_MNSPBIDTRK`. A link's offer in force is the tracking row joined to the other two on `OFFERSETTLEMENTDATE`, `OFFEREFFECTIVEDATE` and `OFFERVERSIONNO`.
- Link capacity and TLFs come from `MNSP_INTERCONNECTOR`; interval `FCASEXPORTLIMIT` and `FCASIMPORTLIMIT` come from `DISPATCHINTERCONNECTORRES`.
- Fast-start: `DISPATCHLOAD.DISPATCHMODE` and `DISPATCHMODETIME` are the interval's target mode and minutes in it. NEMDE's `CurrentMode` and `CurrentModeTime` for interval t are the previous interval's pair, then reset by the profile procedure's pre-processing rules. `MINIMUMLOAD` and T1-T4 are `BIDDAYOFFER_D` columns and `FIXEDLOAD` a `BIDPEROFFER_D` column.
- `MNSP_DAYOFFER.OFFERDATE` and the tracking `OFFEREFFECTIVEDATE` are `TIMESTAMP(3)`; the Data package parses the `.000` fraction, and `OFFERDATE` is `DateTime` in every table.
- A monthly bid archive holds trading days from the 2nd to the 1st of the next month, so a month's first trading day needs the previous month cached.
- Cached months ingested before a column was added read back NULL there until re-populated with `force_new = true`.

## Why

- MNSP participants auto-resubmit a full-day offer every five minutes (about 5 million `MNSP_BIDOFFERPERIOD` rows a month), so latest-version-before-interval is wrong and slow; the tracking table is exact.
- No MMS table carries `CurrentMode` for a run's first interval, so it comes from the previous interval's `DISPATCHLOAD` row.
- `MNSP_OFFERTRK`, `MNSP_FILETRK` and `MNSP_PARTICIPANT` are not cached: the tracking table already names participant and version.
- Pre-5MS MNSP tables (`MNSP_PEROFFER`) are not read, as dispatch run starts at 1 October 2021 ([0073](0073-five-minute-settlement-scope.md)).
