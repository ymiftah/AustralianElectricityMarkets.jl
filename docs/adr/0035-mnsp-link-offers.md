# 0035. MNSP links are offered, bounded and priced per link

## Status

Accepted

## Context

An MNSP is modelled in NEMDE as two links, each offering like a generator (availability, ten price
bands, fixed load, ramp rate), dispatched only when the price spread exceeds its offer. The model
treated Basslink (T-V-MNSP1) as a free-flow regulated interconnector with static limits. Replays
showed Basslink flow errors of 70 to 250 MW and TAS1 price gaps. Stock nempy also treats MNSP links
as free-flow (it reads only `MaxAvail`), so it is no reference for the offered formulation.

Basslink is the only market network service in the sample period (CVP schedule item 2). Murraylink
(V-S-MNSP1) and Terranora (N-Q-MNSP1) are regulated interconnectors; `MNSP_INTERCONNECTOR` still
carries stale 2002 to 2005 rows for them (V-S-MNSP1 has four links), and the older `MNSP_*` rows
are ignored because only links named by `DISPATCH_MNSPBIDTRK` in the interval are used. This change
therefore does not address the Murraylink flow error seen in replays. Basslink gives up its MNSP
registration on 1 July 2026 (Marginal Loss Factors 2026-27, section 5.1); the tracking table is
expected to hold no Basslink rows afterwards, but July 2026 is not cached, so that was not checked.
The fallback applies without change.

## Sources

- AEMO Data Model Report v5.7.0: `MNSP_INTERCONNECTOR` (per link `FROMREGION`, `TOREGION`,
  `FROM_REGION_TLF`, `TO_REGION_TLF`, `LHSFACTOR`, `MAXCAPACITY`), `MNSP_BIDOFFERPERIOD`,
  `MNSP_DAYOFFER`.
- Constraint Violation Penalty Factors: item 16 (MNSP availability, eq 4.1.11, factor 365), item 9
  (total band MW offer, 4.1.10 and 4.1.18, factor 1135), item 17 (MNSP losses, 4.1.12 and 4.1.13,
  a pair of variables at each end, avoiding circulating flow in both offer directions), item 4 (ramp).
- Treatment of Loss Factors section 14: the MLF of each direction of flow applies to the market
  network service, and NEMDE's mixed integer modelling prevents circulating flows.
- Marginal Loss Factors 2026-27, section 5.1: the Basslink loss equation covers the DC leg only; the
  link loss factors represent the AC leg.
- nempy `spot_market_backend/interconnectors.py`: each link's flow enters the regional balances as
  `-from_region_tlf` in its sending region and `+to_region_tlf` in its receiving region ("refer the
  end to the regional reference node"), and the loss share of T-V-MNSP1 is set to 1.0.
- Constraint Implementation Guidelines Table 2: SPD types M and N reference MNSP availability by
  interconnector id. They are not resolved by this change.

The NEMDE formulation document (equations 4.1.10 to 4.1.18) is not in the knowledge base, so those
equations are known only by their CVP schedule descriptions.

## Decision

- **Data.** `read_mnsp_links(db, as_of)` returns the latest `MNSP_INTERCONNECTOR` row per link with
  `EFFECTIVEDATE <= as_of`. `set_mnsp_offers!` keeps the links named by `read_mnsp_offers` in the date
  range, calls the link whose `FROMREGION` is the interconnector's from area the forward link (a link
  starting in neither area is an error), and stores per interconnector a `PiecewiseStepData` offer
  series and a `MAXAVAIL` series per direction (natural MW and `$/MWh`), with link ids and loss factors
  in `ext`. It replaces earlier series when called again. An interconnector offering on only one link,
  or missing an interval, keeps the whole free-flow model with static flow limits, and so does one
  built when the MNSP tables are not cached or the range holds no offer. The first trading day of a
  month sits in the previous month's archive, so that month must be cached too.
- **Formulation.** Under `NEMInterconnectorLoss`, an interconnector carrying both offers gets one
  non-negative `MNSPLinkFlowVariable` per direction and timestep, bounded by `min(MAXAVAIL, sum of
  bands)`, with `flow = forward - reverse`. Band prices enter the objective unreferred. A link's flow
  `q` also adds `-(from_tlf - 1) q` to its sending area balance and `(to_tlf - 1) q` to its receiving
  area balance, so the delivered MW are `to_tlf * q` and the offer clears when
  `P <= to_tlf * price_to - from_tlf * price_from`. The loss model, share, flow limits and generic
  constraint terms are untouched, so MNSP interconnector terms keep resolving, and the ordered loss
  segments compose unchanged.
- **Loss factors.** Nempy's convention is followed: the link loss factors, not the DC-leg loss model,
  carry the AC-leg loss. AEMO publishes no rule for referring an offer price by a loss factor, so none
  is applied.
- **Circulation.** The two links never flow at once: `MNSPLinkDirectionVariable` is a binary per
  interconnector and timestep that gates one link or the other, and it is a PSI variable container so
  the dual pass fixes it and balance duals stay available. It is imposed always, not only when the
  cheapest offers sum below zero: with `flow = forward - reverse`, a zero net flow (a zero-flow
  generic constraint such as VT_ZERO or TV_ZERO) would otherwise still allow `forward = reverse > 0`,
  and because each link injects `(tlf - 1) q` at both ends that circulation can create or destroy
  energy whenever regional prices exceed the summed band prices.
- **Basslink loss share.** `FROMREGIONLOSSSHARE` is 0.0 in AEMO's data for T-V-MNSP1. Following nempy,
  `interconnector_loss_models` sets it to 1.0. This is an empirical departure from the data, kept to
  replicate NEMDE outcomes, not a documented AEMO rule.
- **Availability** is a hard bound. AEMO penalises it elastically (items 16 at 365 and 9 at 1135);
  these belong with the elastic-row work for the other hard families.
- **Flow-limit series.** Offer series are skipped when deciding whether an `AreaInterchange` carries
  per-interval flow-limit series.

## Remaining work

- `FIXEDLOAD`, the per-link ramp (needs the metered MNSP flow as initial condition), `MAXCAPACITY` and
  `LHSFACTOR` are read but unused.
- SPD types M and N (MNSP availability on the right-hand side of constraints).
- Real-data validation against the TAS1 and T-V-MNSP1 gaps.
