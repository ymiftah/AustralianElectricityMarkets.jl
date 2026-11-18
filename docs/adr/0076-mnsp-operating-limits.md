# 0076 MNSP commercial limits and operating inputs

## Status

Accepted. Amends [0035](0035-mnsp-link-offers.md) for commercial limits, ramps and fixed loading.

## What

For each non-negative directional link flow `q` with bounded offer-band variables `b`:

- `q = sum(b) + offer_surplus` (priced at CVP 1135, `MNSP_OFFER_CVP_FACTOR`).
- `q - availability_surplus <= MAXAVAIL` (CVP 365, `MNSP_AVAILABILITY_CVP_FACTOR`).
- The surpluses are independent and non-negative. The direction binary keeps one link available at a time and is bounded by that direction's endpoint of the loss-model flow domain, not by MAXAVAIL or offered MW; otherwise the surpluses could not relax the limits.
- Net ramp, signed net flow `x`, metered initial flow `x0`, interval `dt` minutes, forward and reverse ramp rates `Rf`, `Rr`: `x - ramp_up_surplus <= x0 + dt*Rf` and `x + ramp_down_deficit >= x0 - dt*Rr`, each violation at CVP 1155 (`MNSP_RAMP_CVP_FACTOR`). There are no per-direction ramps, which would double-count a reversal.
- Fixed loading: an invoked instruction fixes the directional `q` to FIXEDLOAD with surplus and deficit slacks at CVP 380 (`FIXED_LOADING_CVP_FACTOR`). A numeric zero is an active instruction; an uninvoked row is relaxed by the link's loss-domain bound.
- Costs use system base power, interval hours and the per-interval Market Price Cap. Violations are reported in MW, with the link direction kept for directional rows.

## How

- Slacks are `MNSPSlack` variables keyed by variant (`MNSPMaxAvailVariant`, `MNSPOfferVariant`, `MNSPRampUpVariant`, `MNSPRampDownVariant`, `MNSPFixedLoadSurplusVariant`, `MNSPFixedLoadDeficitVariant`) and link; rows are `MNSPLinkConstraint`; costs in `formulations/mnsp_limits.jl`.
- AEM attaches initial flow, ramp rates (MW/min) and fixed load with its invoked flag as series, read through `MNSPOperatingParameter`.

## Sources

- AEMO *Schedule of Constraint Violation Penalty Factors* v8.0: item 4 MNSP ramping CVP 1155 (p. 8); item 9 MNSP total band MW CVP 1135 (p. 11); item 13 participant fixed loading CVP 380 (p. 13); item 16 MNSP availability CVP 365 (p. 15), which expressly lets a fixed loading override availability.
- AEMO *Electricity Data Model Report* v5.7.0: MNSP_BIDOFFERPERIOD pp. 67-69 (RAMPUPRATE MW/min in the link's positive direction, FIXEDLOAD MW); DISPATCHINTERCONNECTORRES pp. 269-271 (METEREDMWFLOW is SCADA flow, MWFLOW the dispatch target); MNSP_INTERCONNECTOR pp. 517-518 (link direction and terminal loss factors).

## Departures from AEMO

- The two-end MNSP loss violation equations (schedule item 17), Basslink converter losses, its no-go zone and the frequency-controller alternative runs are not modelled. Loss-curve endpoint bounds and the hard loss-split equality remain.
- Historical MNSP versus post-conversion regulated operation follows the standing `ICTYPE`; a run crossing a type change must be split.
