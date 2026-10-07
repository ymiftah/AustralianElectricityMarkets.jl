# 0041. The 1-second FCAS markets are modelled as contingency services

## Status

Accepted. Supersedes 0040.

## Context

`RAISE1SEC` and `LOWER1SEC` (very fast raise and lower, from 9 October 2023) were excluded from
`FCAS_BID_TYPES`. Their requirement rows were dropped by `read_fcas_requirements`, no
`FCASService` existed for them, and the generic constraints that carry them (`F_*_R1`, `F_*_L1`)
were built with their 1-second terms contributing zero (0040). Batteries, about 60 percent of
enabled raise MW in June 2026, were also unconstrained by the 1-second trapezium that binds them in
NEMDE.

## Decision

Treat the 1-second services exactly as the other contingency services. AEMO *FCAS Model in NEMDE*
v3.0 (release 2.0 added Very Fast Contingency FCAS) applies the same unit FCAS constraints to every
contingency service (section 6, Table 2: joint capacity applies, joint ramping and the
energy-and-regulation row do not) and §6.2 lists one set of joint capacity constraints per
contingency service, very fast raise and lower included. Section 4 applies no trapezium scaling to
contingency bids, so the 1-second trapezium is the bid trapezium. Section 5 pre-conditions are
the contingency ones, and a battery's contingency trapezium stays on the net-MW axis.

- `FCAS_CONTINGENCY_MARKETS` gains `RAISE1SEC` and `LOWER1SEC`, so `FCAS_BID_TYPES` has ten markets
  (eight contingency, two regulation). Every reader and setter that loops over `FCAS_BID_TYPES`
  (bids, requirements, prices, dispatch outcomes, `add_fcas_services!`) picks them up, and skips
  them where a cached month predates the markets (the columns and rows are absent before
  2023-10-09).
- `FCASMarket` needs no change: it is generic over the contingency services, including the
  regulation targets on the upper and lower rows of the joint capacity constraint. Its elastic
  capacity rows use the same capacity violation penalty as the other contingency services.
- The `F_*_R1`/`F_*_L1` requirement rows are built like every other requirement row, with their
  `GENERICCONSTRAINTWEIGHT` (CVP items 39 and 40, factor 9, above the 6-second requirement CVP).
  `compute_fcas_prices` prices `RAISE1SEC`/`LOWER1SEC` from their duals unchanged.
- The pre-flight guard of 0040 is removed: with every non-energy `BidType` modelled, the existing
  `:unmodeled_fcas_service` reason (a service with devices and no `FCASMarket` model) covers the
  remaining case.

## Not covered

- Scheduled loads and wholesale demand response units offering any FCAS (a separate gap).
- Data before 2023-10-09: no 1-second bids, requirements or prices exist, so no 1-second services
  are created.

## Consequences

- A replica interval has 10 FCAS prices per region instead of 8. Comparison tables gain 1-second
  rows.
- Mock data in the shared fixture carries the 1-second markets, so all three suites cover them.
