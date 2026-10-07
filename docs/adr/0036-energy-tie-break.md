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
pairs of the same unit, de-duplicates the pair, and builds one equality per pair:
`x_i / ub_i - x_j / ub_j = 0`. `markets.py` `set_tie_break_constraints(cost)` then makes these rows
elastic (`make_constraints_elastic('tie_break', violation_cost=cost)`, form
`B1/C1 - B2/C2 + D1 - D2 = 0`), so nempy also has fraction-valued slacks priced at `cost`, which is
1e-6 when fed with the XML case. A 0.0203 stand-in made no measurable difference.

## Decision

- **Constraints, not an objective perturbation.** AEMO and nempy both use equality rows on fill
  fractions. A tiny price perturbation would not reproduce the proportional split (it would pick a
  vertex again), so it is not used.
- **Elastic pairs, as AEMO and nempy.** Each pair is `x_a/w_a - x_b/w_b + up - down = 0` with
  both slacks, in fill fraction, priced at `TIE_BREAK_CVP_FACTOR` (1e-6) per dispatch interval (the
  same scale as nempy's `cost`; no system-base factor, since the slacks are dimensionless). The
  penalty is far below any bid price difference, so a tie never displaces a competitively priced
  band. A band held back by a ramp or availability limit relaxes its pairs.
- **All pairs, not a chain.** Every pair of bands of different units in a tie group gets a row,
  as nempy and FAQ 3.19 ("for that pair of price-tied bands"): n(n-1)/2 rows and as many slack
  pairs. A chain was tried first and is wrong: when one band is held back, the chain's total slack
  is linear in the other fills, so the LP fills one band to 1 first and the answer depends on the
  DUID sort order; with all pairs the held-back band's neighbours are also tied to each other
  (`|fA - fC|`), so they stay pro rata. Groups are small (worst case about 100 bands, about 5000
  rows).
- **Detection.** Per (direction, region, time step): offer bands and load-bid bands are separate
  groups; the region is the area of the device's bus; prices are the market-bid slopes divided by
  the system base, which are already referred to the reference node by the bid setter. Sorted
  prices are grouped while consecutive prices differ by at most 1e-6 $/MWh. Zero-width bands are
  skipped. Pairs of the same unit are excluded, as nempy does. Tolerance is applied between
  consecutive sorted prices, so a run of prices each within 1e-6 of the next ties transitively.
- **Energy only.** FCAS offers are not tied, as in the FAQ and item 53.
- **Where it lives.** `add_tie_break_constraints!` reads the PSI block variables, breakpoints and
  slopes after every device's bid objective, so it crosses device types (wind against solar in a
  region is the common case). It is called from the `AreaBalancePowerModel` objective hook, the
  only network-stage hook that runs after all device models, and therefore exists only with
  `use_slacks = true`, which the replication template always sets.

## Consequences

- LP size grows by n(n-1)/2 rows and twice as many columns per tie group and interval; groups are
  small except for the market-floor bids of wind and solar in one region.
- A feasible tie adds zero cost. Prices differing by less than the tolerance still have an
  economic effect when the saved cost exceeds the slack penalty: the penalty per fill fraction is
  about 8e-8 $ (1e-6 over twelve intervals per hour), so a band 0.5e-6 dearer is simply not
  dispatched. Tied bands in real data are equal to rounding, so this does not arise there.
- When a tied band is held back by a ramp or availability limit its pairs are violated and the
  balance dual can carry the penalty, below 1e-6 $/MWh in the toy tests. The slack rows and
  variables are plain JuMP objects, not registered PSI keys, so violated pairs cannot be read from
  results.
- The 2026-06-09 TAS1 LOWERREG price moved by +1.0 in an earlier run (3.08 with the tie-break
  against 2.08 without, published 1.56): a degenerate-dual sensitivity to re-check after the slack
  scaling was corrected.
- **Hook placement.** The links are added from the `AreaBalancePowerModel` objective hook, the only
  network-stage hook that runs after every device model. Models built with another network model,
  or `use_slacks = false`, get arbitrary tie vertices, and bid blocks created by branch or service
  models are never tied; the `set_nem_dispatch_models!` and `replication_template` docstrings say
  so. `add_tie_break_constraints!` is not exported.
- A model with binary variables solved with default optimizer MIP gaps may ignore the tie
  penalty, which is below those tolerances.
- Bid data must be fixed at build: slopes and breakpoints are read with `PSI.jump_fixed_value`,
  and a recurrent (`Simulation`) build throws an `ArgumentError`. The replication path rebuilds
  per interval.
- Not tested by a solve: two regions with equal prices staying separate (the toy has one area).
  The grouping key includes the region.
