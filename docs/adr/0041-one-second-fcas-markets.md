# 0041 The 1-second FCAS markets are modelled as contingency services

## Status

Accepted

## What

- `RAISE1SEC` and `LOWER1SEC` (very fast raise and lower, from 9 October 2023) are contingency FCAS markets like the 6-second, 60-second and 5-minute ones.
- A replica interval has ten FCAS prices per region (eight contingency, two regulation).

## How

- `FCAS_CONTINGENCY_MARKETS` includes both, so `FCAS_BID_TYPES` has ten entries. Readers, setters and `add_fcas_services!` that loop over `FCAS_BID_TYPES` pick them up with no special case.
- `FCASMarket` is generic over contingency services: unit capacity rows, regulation targets on the joint capacity rows and elastic capacity rows are unchanged.
- The `F_*_R1` and `F_*_L1` requirement rows are built like every other requirement row, with their `GENERICCONSTRAINTWEIGHT`. `compute_fcas_prices` prices them from the duals unchanged.
- Months cached before 2023-10-09 have no 1-second bids, requirements or prices, so no 1-second services are created for them.
- Scheduled loads and wholesale demand response offering FCAS remain unmodelled.

## Why

- AEMO, *FCAS Model in NEMDE* v3.0 (release 2.0 added Very Fast Contingency FCAS): section 6 Table 2 applies the same unit constraints to every contingency service (joint capacity applies; joint ramping and the energy-and-regulation row do not); §6.2 lists one joint capacity set per contingency service, 1-second included.
- Section 4 applies no trapezium scaling to contingency bids, so the 1-second trapezium is the bid trapezium. Section 5 pre-conditions are the contingency ones, and a battery's contingency trapezium stays on the net-MW axis.
- Leaving the markets out left the `F_*_R1`/`F_*_L1` rows with zero terms (always violated) and batteries, a large share of enabled raise MW, unconstrained by the 1-second trapezium that binds them in NEMDE.
- The `:unmodeled_fcas_service` pre-flight reason already covers any market with devices and no `FCASMarket` model, so no extra guard is needed.
