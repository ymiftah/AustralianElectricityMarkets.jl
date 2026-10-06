# 0035. MNSP links are offered, bounded and priced per link

## Status

Accepted

## Context

Basslink (T-V-MNSP1), Murraylink (V-S-MNSP1) and Terranora (N-Q-MNSP1) were modelled as free-flow
regulated interconnectors with static `MAXMWIN`/`MAXMWOUT` limits. In NEMDE each is a market network
service with two links; each link offers like a generator (availability, ten price bands, fixed load,
ramp rate) and is dispatched only when the price spread exceeds its offer. Replays showed Murraylink
flowing 80 MW against a published zero, Basslink flow errors of 70 to 250 MW and TAS1 price gaps.
Stock nempy also treats MNSP links as free-flow (it reads only `MaxAvail`), so it is no reference for
the offer-priced model.

## Sources

- AEMO Data Model Report v5.7.0: `MNSP_INTERCONNECTOR` (per link `FROMREGION`, `TOREGION`,
  `FROM_REGION_TLF`, `TO_REGION_TLF`, `LHSFACTOR`, `MAXCAPACITY`), `MNSP_BIDOFFERPERIOD` and
  `MNSP_DAYOFFER` (availability and bands).
- Constraint Violation Penalty Factors: item 16 (MNSP availability, NEMDE equation 4.1.11), item 9
  (total band MW offer, 4.1.10 and 4.1.18), item 17 (MNSP losses, 4.1.12 and 4.1.13, avoiding
  non-physical circulating flow in both offer directions), item 4 (MNSP ramp rate, 4.1.14, 4.1.15).
- Treatment of Loss Factors, section 14: the MLF of each direction of flow applies to the market
  network service, and NEMDE's mixed integer modelling prevents circulating flows (from 1 July 2012).
- Constraint Implementation Guidelines Table 2: SPD types M and N reference MNSP availability by
  interconnector id. They are not resolved by this change.

The NEMDE formulation document itself (equations 4.1.10 to 4.1.18) is not in the knowledge base, so
the equations above are known only by their CVP schedule descriptions.

## Decision

- **Data.** `read_mnsp_links` returns the latest `MNSP_INTERCONNECTOR` row per link. `set_mnsp_offers!`
  joins `read_mnsp_offers` to it, calls the link whose `FROMREGION` is the interconnector's from area
  the forward link, and stores per interconnector a `PiecewiseStepData` offer series and a `MAXAVAIL`
  series per direction (natural MW and `$/MWh`), plus link ids and loss factors in `ext`.
  An interconnector missing either link or any interval keeps the free-flow model, with a warning.
- **Formulation.** Under `NEMInterconnectorLoss`, an interconnector carrying both offers gets one
  non-negative `MNSPLinkFlowVariable` per direction and timestep, bounded by `min(MAXAVAIL, sum of
  bands)`, with `flow = forward - reverse`. Each link's bands enter the objective at price divided by
  the link's `FROM_REGION_TLF`, the referral used for generator offers. The existing flow variable, the
  loss model, the from-region share, static or interval flow limits and generic constraint terms are
  untouched, so terms on an MNSP interconnector id keep resolving and the loss encoding (ordered
  segments) composes without change.
- **Circulation.** If the two links' lowest offers sum below zero, circulating both links is
  profitable at a convex cost. Those timesteps get a binary selecting one direction, matching NEMDE's
  mixed integer treatment. The rest stay linear.
- **Time series.** The offer series are skipped when deciding whether an `AreaInterchange` carries
  flow-limit series.

## Departures and assumptions

- Loss factors: only the sending-end `FROM_REGION_TLF` scales the offer price. `TO_REGION_TLF` is
  recorded but not applied to quantities, because the loss model already carries the physical
  loss. Whether NEMDE also scales delivered MW by the link loss factors is unverified.
- **Basslink loss share**: `FROMREGIONLOSSSHARE` is 0.0 in AEMO's data and is used as published.
  Nempy hardcodes 1.0. No change is made here.
- Availability is hard. AEMO penalises it elastically (CVP item 16, factor 365), which belongs with
  the elastic-row work for the other hard families.

## Remaining work

- Fixed load (`FIXEDLOAD`), the per-link ramp (`RAMPUPRATE`, equations 4.1.14 and 4.1.15, needing the
  metered MNSP flow as the initial condition), `MAXCAPACITY` and `LHSFACTOR` (the factor applied to
  generic constraint terms) are read for links but unused.
- SPD types M and N (MNSP availability on the right-hand side of constraints).
- Basslink ceases MNSP registration on 1 July 2026, after which it is a regulated interconnector and
  has no offers; the fallback applies without change.
- Real-data validation against the TAS1, V-S-MNSP1 and T-V-MNSP1 gaps.
