# 0035 MNSP links are offered, bounded and priced per link

## Status

Accepted. Commercial limits, ramps and fixed loading are amended by [0076](0076-mnsp-operating-limits.md).

## What

- An MNSP interconnector (`ICTYPE = MNSP`; Basslink `T-V-MNSP1` in the sample period) is modelled as a forward and a reverse link, each offering like a generator: availability, ten price bands, priced per link. Regulated interconnectors (Murraylink, Terranora) keep the free-flow loss model.
- Stock nempy treats MNSP links as free-flow, so it is no reference for the offered form.

## How

- `set_mnsp_offers!` attaches per direction a `NEMMNSPLink` and a `NEMMNSPBid` (bands, `MAXAVAIL`, ramp, fixed load); the forward link runs from the interconnector's `from_area`. An MNSP missing a link or an interval input throws. A repeat call replaces earlier data.
- Under `NEMInterconnectorLoss`, per direction and timestep: non-negative `MNSPLinkFlowVariable`, band variables, and `MNSPLinkLossVariable`; `flow = forward - reverse`. Band prices enter the objective unreferred.
- A link flow `q` adds `-(from_tlf - 1) q` to its sending area balance and `(to_tlf - 1) q` to its receiving area balance. Each directional loss, zero on the inactive link and summing to the interconnector loss (`loss_split`), enters the sending area at `from_tlf`.
- `MNSPLinkDirectionVariable` is a binary per interconnector and timestep, always imposed. A zero net flow (a zero-flow constraint) would otherwise allow `forward = reverse > 0`, and each link injects `(tlf - 1) q` at both ends, so the circulation could create or destroy energy.
- `T-V-MNSP1`'s `FROMREGIONLOSSSHARE` is set to 1.0 as nempy does ([0091](0091-interconnector-loss-input-assumptions.md)).

## Why

- Runs showed Basslink flow errors of 70 to 250 MW and TAS1 price gaps under free flow.
- Link loss factors, not the DC-leg loss model, carry the AC-leg loss (Marginal Loss Factors 2026-27, section 5.1; nempy `interconnectors.py`). AEMO publishes no rule for referring an offer price by a loss factor, so none is applied.
- The offer clears when `P <= to_tlf * price_to - from_tlf * price_from`.
- Treatment of Loss Factors section 14: the MLF of each direction applies, and NEMDE's mixed-integer modelling prevents circulating flows.

## Sources

- CVP Schedule v8.0: item 16 (MNSP availability, 365), item 9 (total band MW, 1135), item 17 (MNSP losses, 4.1.12 and 4.1.13), item 4 (ramp).
- NEMDE equations 4.1.10 to 4.1.18 are not in the knowledge base; they are known only by their CVP descriptions.
- SPD types M and N (MNSP availability on a constraint right-hand side) are not resolved.
