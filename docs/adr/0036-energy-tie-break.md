# 0036. Price-tied energy bands clear pro rata, with elastic links

## Status

Accepted

## Context

When energy bands of different units are price-tied and the group is marginal, NEMDE dispatches
them in proportion to band MW through a tie-break constraint per pair of tied bands (Constraint
FAQ 3.19: "dispatched in proportion to the MW sizes of the respective marginal bid bands through
the tie-breaking constraint equation created for that pair of price-tied bands", energy only, not
FCAS). Item 53 of the Schedule of Constraint Violation Penalty Factors gives the slack variables
`TBSlack1` and `TBSlack2` a factor of 1e-6, and defines tied as prices "adjusted by intra-regional
loss factors" within 1e-6 of one another, per region and per bid type. The replica had none, so
HiGHS returned an arbitrary vertex: on 2026-06-03 DUNDWF1/2/3 all bid -984.5 with bands 168/46/122
MW under a 168 MW group limit; published and nempy give 84/23/61, the replica 100/0/68. The
diagnosis counted up to 67 of 216 unit-gap rows inside tied bands.

nempy's `unit_constraints.tie_break_constraints` merges energy bids with themselves on
`['cost', 'region', 'dispatch_type']` (exact equality of the loss-factor-adjusted cost), drops
pairs of the same unit, de-duplicates the pair, and adds one hard equality per pair:
`x_i / ub_i - x_j / ub_j = 0` (coefficients `1/ub` and `-1/ub`, right-hand side 0). It has no
slack, so a tied band that a ramp or availability limit holds below the common fill fraction makes
the model infeasible or forces the other units down. Stock nempy fed with the XML case uses 1e-6
for the tie-break price (a ranking-neutral value); a 0.0203 stand-in made no measurable
difference.

## Decision

- **Constraints, not an objective perturbation.** AEMO and nempy both use equality rows on fill
  fractions. A tiny price perturbation would not reproduce the proportional split (it would pick a
  vertex again), so it is not used.
- **Elastic links, as AEMO.** Each link is `x_a/w_a - x_b/w_b + up - down = 0` with both slacks
  priced at `TIE_BREAK_CVP_FACTOR` (1e-6). The slacks are in fill fraction, priced at 1e-6 times
  the system base per interval hour, which is far below any bid price difference, so a tie never
  displaces a competitively priced band and regional prices do not move. A band held back by a
  ramp or availability limit relaxes its link instead of forcing infeasibility (nempy's hard form
  would).
- **Chain, not all pairs.** Tied bands of a group, sorted by price, are linked consecutively:
  n-1 rows and 2(n-1) slacks per group, rather than nempy's n(n-1)/2 rows. With the slacks at
  zero the two are equivalent (equal fractions along a chain imply equal fractions pairwise).
- **Detection.** Per (direction, region, time step): offer bands and load-bid bands are separate
  groups; the region is the area of the device's bus; prices are the market-bid slopes divided by
  the system base, which are already referred to the reference node by the bid setter. Sorted
  prices are chained while consecutive prices differ by at most 1e-6 $/MWh. Zero-width bands are
  skipped. Same-unit tied bands are linked too (nempy excludes them); equal fractions of two
  equally priced bands of one unit leave the unit's total and cost unchanged.
- **Energy only.** FCAS offers are not tied, as in the FAQ and item 53.
- **Where it lives.** `add_tie_break_constraints!` reads the PSI block variables, breakpoints and
  slopes after every device's bid objective, so it crosses device types (wind against solar in a
  region is the common case). It is called from the `AreaBalancePowerModel` objective hook, the
  only network-stage hook that runs after all device models, and therefore exists only with
  `use_slacks = true`, which the replication template always sets.

## Consequences

- LP size grows by n-1 rows and 2(n-1) columns per tie group and interval; groups are small
  except for the market-floor bids of wind and solar in one region.
- Regional prices and the objective are unchanged apart from slack cost: a feasible tie adds
  zero. When a tied band is held back by a ramp or availability limit its link is violated and the
  balance dual carries the penalty, about 1e-6 $/MWh in the toy (20.000001 against 20); AEMO's
  published prices carry the same term. Tests of such cases use a 1e-5 price tolerance.
- The block variables carry the cost (PWL MarketBidCost step data); the links constrain those
  variables directly, so no change to the cost representation is needed.
- Time-variant offers are read at build, so a parameter update that changes which bands tie
  without a rebuild keeps the build-time groups. The replication path rebuilds per interval.
- Open: AEMO's slack unit is not documented; fraction-valued slacks at 1e-6 are a choice, not
  a quoted value.
