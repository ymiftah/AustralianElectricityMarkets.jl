# 0064 Total offered energy bands are elastic

## Status

Accepted. Extends [0062](0062-elastic-energy-limits.md); always on per [0068](0068-device-rows-always-elastic.md).

## What

- Each offered band keeps its `EnergyOfferBandVariable`, quantity bound and bid cost. Dispatch is linked to the cleared bands through slacks:

```text
dispatch = sum(cleared_band_MW) + above_offer_slack - below_offer_slack
```

- Each slack costs `ENERGY_OFFER_CVP_FACTOR` (1135) times the Market Price Cap, base power and interval hours; a violation has no offer price beyond the submitted bands, and band costs apply to cleared offered quantity only.
- Source: AEMO *Schedule of Constraint Violation Penalty Factors* v8.0 Table 1 item 8 (Total Band MW Offer, DeficitOfferMW and SurplusOfferMW, 1135). Non-conformance (item 2) and unit ramp (item 3) outrank it, MaxAvail (item 14, 370) is below it.
- Not reproduced: AEMO's over-constrained pricing rerun procedure.

## How

- `NEMUnitSlack` variants `energy_offer|surplus`, `deficit`, `decremental_surplus` and `decremental_deficit`, allocated only for devices with that offer direction (`gen` side, and `load` side for scheduled loads and storage); violations report under family `energy_offer`.
- Band widths are live `EnergyBandWidthParameter`s, so per-step updates do not freeze the first interval's quantities. FCAS bands, MNSP offers and tie-break bands are unaffected.

## Why

- A hard dispatch-equals-bands link makes total offered MW an immutable limit, where NEMDE violates it when higher-priority constraints require.
- A dispatch exceeding both availability and offered bands pays both penalties.
