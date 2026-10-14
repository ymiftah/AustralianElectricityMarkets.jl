# 0034. MMS tables for MNSP offers and fast-start state

## Status

Accepted

## Context

Two replication gaps need data the Data package did not cache: market network service provider
(MNSP) offers for the three merchant links, and the fast-start state NEMDE starts each interval
from (current mode, time in mode, minimum load, T1 to T4). The AEMO MMS Data Model (v5.7.0) and
the fast-start inflexibility profile procedure were checked for which tables carry them.

## Decision

- **MNSP offers use the five-minute tables.** `MNSP_DAYOFFER` (price bands; key LINKID,
  OFFERDATE, PARTICIPANTID, SETTLEMENTDATE, VERSIONNO), `MNSP_BIDOFFERPERIOD` (MAXAVAIL,
  FIXEDLOAD, RAMPUPRATE, BANDAVAIL1-10 per 5-minute PERIODID 1-288; key LINKID, OFFERDATETIME,
  PERIODID, TRADINGDATE) and `DISPATCH_MNSPBIDTRK` (the offer version each dispatch run applied;
  key LINKID, PARTICIPANTID, RUNNO, SETTLEMENTDATE). A link's offer in force at an interval is
  `DISPATCH_MNSPBIDTRK` joined to the other two on OFFERSETTLEMENTDATE, OFFEREFFECTIVEDATE (equal
  to OFFERDATE and OFFERDATETIME) and OFFERVERSIONNO. MNSP participants auto-resubmit a full-day
  offer every five minutes, so `MNSP_BIDOFFERPERIOD` is about 5 million rows a month; selecting by
  latest-version-before-interval would be wrong and expensive, the tracking table is exact.
- **`MNSP_PEROFFER` is cached but historical.** AEMO publishes no months after the move to five-minute
  settlement, so the 2026 archives return 404; the spec exists for pre-October-2021 days.
- **`MNSP_OFFERTRK`, `MNSP_FILETRK` and `MNSP_PARTICIPANT` are not cached.** The tracking table
  already names participant and bid version; the file-tracking tables have no consumer.
- **Link capacity and TLFs** (LINKID, FROMREGION, TOREGION, FROM_REGION_TLF, TO_REGION_TLF,
  LHSFACTOR, MAXCAPACITY) were already in `MNSP_INTERCONNECTOR`.
- **Interval limits** `FCASEXPORTLIMIT` and `FCASIMPORTLIMIT` are added to
  `DISPATCHINTERCONNECTORRES`; the energy-only limits, flows and losses were already there.
- **Fast-start state is in `DISPATCHLOAD` and the bid tables, as outputs.** `DISPATCHLOAD.DISPATCHMODE`
  is the target mode of the interval and `DISPATCHMODETIME` (added) the minutes in it, from the
  NEMDE TRADERSOLUTION attributes. NEMDE's CurrentMode and CurrentModeTime for interval t are the
  previous interval's published pair, so they are derived from the interval before, then reset by the
  pre-processing rules of the profile procedure (slow to fast start, or MaxAvail zero). MINIMUMLOAD and
  T1-T4 are `BIDDAYOFFER_D` columns and FIXEDLOAD a `BIDPEROFFER_D` column, all already cached. No MMS
  table carries a CurrentMode input for the first interval of a run; a replay from published
  INITIALMW has to take the previous interval's `DISPATCHLOAD` row.
- **Timestamp parsing accepts a millisecond fraction.** `MNSP_DAYOFFER.OFFERDATE` and the tracking
  OFFEREFFECTIVEDATE are TIMESTAMP(3) and arrive as `2026/05/05 15:06:01.000`; the plain format
  yielded NULL. `OFFERDATE` is typed `DateTime` for every table (DATE in `MNSP_PEROFFER`).

## Consequences

- Cached months of `DISPATCHLOAD` and `DISPATCHINTERCONNECTORRES` ingested earlier read back NULL
  in the new columns until re-populated with `force_new = true`.
- A monthly MMSDM bid archive holds trading days from the 2nd of the month to the 1st of the next, so
  the first trading day of a month (including its 00:00 to 04:00 intervals on the 1st) needs the
  previous month cached to resolve its offers.
- `read_mnsp_offers` returns offers only; mapping links to the `System`, link TLFs and the energy
  path are left to the MNSP gap.
