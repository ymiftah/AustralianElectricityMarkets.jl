# 0036. Price-tied energy bands clear pro rata, with elastic links

## Status

Accepted. Amended: the rows moved from the network objective hook to a registered PSI service
model (see "Where it lives").

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
- **Elastic pairs, as AEMO and nempy.** A band held back by a ramp, availability or group limit
  relaxes its rows through an up and a down slack instead of making the model infeasible.
- **Rows in MW, not in fill fraction.** Each pair of bands a, b of different units gets
  `(x_a w_b - x_b w_a) / w_ref + up - down = 0`, with `x` the cleared MW, `w` the band width and
  `w_ref` the widest band of the tie group, so the slacks are system-base per-unit MW priced at
  `TIE_BREAK_CVP_FACTOR` ($/MWh, 1e-6, times the base and the interval hours). This is the same
  equality as nempy's `x_a/w_a - x_b/w_b = 0` (a multiple of it) and the same proportionality
  AEMO states, but the multiple matters once rows are violated. With fraction rows the penalty on
  band i against a held-back band k is `|f_i - f_k|`, so the cost per MW of band i is `1/w_i`: when
  most of a large tie group is held back at other fractions (36 floor-priced bands in VIC1, most of
  them coal at ramp limits and wind at UIGF), the LP prefers to load the narrowest band of a
  group-limited subset first and the split is an arbitrary vertex. With the rows above the cost per
  MW of band i against band k is `w_k / w_ref` whatever i is, so the held-back bands add the same
  marginal cost to every member of a limited subset and its split is set by its own rows alone,
  proportional to band MW. The toy test reproduces the failure (151/5/12 MW instead of 84/23/61
  under the fraction form) and the replay of DUNDWF1/2/3 confirms it (below).
- **Penalty size.** The 1e-6 CVP factor is kept, as AEMO and nempy, but as $/MWh of violation
  rather than per unit of fill fraction. A fraction slack at 1e-6 per interval hour is 8.3e-8 per
  fraction, below HiGHS' dual feasibility tolerance (1e-7), and the solver then treats the slack
  as free; the earlier fraction form at that price regressed the DUNDWF splits on 2026-06-09 and
  2026-06-12. In per-unit MW the slack column costs 8.3e-6, 80 times the tolerance, and the
  summed effect on any band's marginal cost (a few dozen rows of at most 8.3e-8 $/MW) is far below
  the cent resolution of bid prices. This deviates from AEMO's absolute unit, which the schedule
  does not state; nempy's `cost` is likewise applied to its own slack units. Tightening the
  optimizer tolerance does not help (a 1e-10 dual tolerance moved 2026-06-03 to 66/29/73), so the
  scaling is the fix. The penalty is not MPC-scaled (the XML case uses 1e-6 literally).
- **All pairs, not a chain.** Every pair of bands of different units in a tie group gets a row,
  as nempy and FAQ 3.19 ("for that pair of price-tied bands"): n(n-1)/2 rows and as many slack
  pairs. A chain depends on the DUID sort order once a band is held back, and a hub with a free
  common fill is not neutral either (a limited subset again fills its narrowest band first), so
  neither is used. The all-pairs rows are what make the held-back bands cost-neutral across a
  limited subset.
- **Detection.** Per (direction, region, time step): offer bands and load-bid bands are separate
  groups; the region is the area of the device's bus; prices are the y-coordinates of the units'
  offer curves (`PiecewiseStepData`, natural units) at each time step, which the bid setter has
  already referred to the reference node. Sorted
  prices are grouped while consecutive prices differ by at most 1e-6 $/MWh. Segments that are empty
  at every timestamp of the offer series are skipped (an unused top band at the price cap would
  only add vacuous rows); a segment empty at some timestamps stays in its group with a zero scale,
  so the tied pairs are the same at every step. Pairs of the same unit are excluded, as nempy does. Tolerance is applied between
  consecutive sorted prices, so a run of prices each within 1e-6 of the next ties transitively.
- **Energy only.** FCAS offers are not tied, as in the FAQ and item 53.
- **Scales are parameters.** The rows are built once with unit placeholder coefficients; the scale
  `w / w_ref` of each band is a constraint-coefficient parameter read from the unit's
  `"tie_break_scale_<k>"` series, so a recurrent simulation updates it per step. Offer curves keep
  every price band as a segment (zero width when empty), so segment `k` is always the same price
  band. The tied pairs are fixed at build; `check_tie_break_pairs` rejects a range over which they
  change, which only happens between trading days.
- **Where it lives.** The rows are a PSI service model, `ServiceModel(EnergyTieBreak,
  TieBreakMarket, "energy_tie_break")`. `EnergyTieBreak <: PSY.Service` lives in the top-level
  package so `System` JSON round-trips; `set_tie_break_scales!` replaces it on every call with one
  whose contributors are all available `MarketBidCost` units, whether or not they carry scales, so
  the build-time checks still run when nothing ties. `set_nem_dispatch_models!` registers the
  service model whenever the system carries the service (`tie_breaks = false` leaves it out). The
  argument stage is a no-op; the model stage (step 7 of PSI's build order, after every device's bid
  objective) reads the PSI block variables and the units' offer curves, so it crosses device types (wind
  against solar in a region is the common case) and works under any network model. Slacks are
  registered as `TieBreakSlackUp`/`TieBreakSlackDown` (`SparseVariableType`, keyed `(label, pair,
  t)` with `label = "<region>_offer"` or `"<region>_bid"`, not written to results like PSI's own
  piecewise variables) and rows as `TieBreakConstraint`, all keyed by `EnergyTieBreak` with the
  service name as meta. No container is added when nothing ties: PSI's MILP dual pass
  (`process_duals`) reads the first element of every variable container and fails on an empty one.
  The "unmodelled unit carrying scales" check iterates the service's
  contributing devices from the system, not PSI's filtered contributor map, so a contributor whose
  type has no device model is still reported; when no contributor type is modelled at all, PSI
  itself rejects the template ("contributing devices ... is empty"). PSI skips a service model whose
  service is absent from the system without error, which is why the setter always attaches it.
  Earlier the rows were plain JuMP objects added from the `AreaBalancePowerModel` objective hook
  behind a settings `ext` switch, which tied them to `use_slacks = true`, could not be read back and
  was not visible in the template.

## Consequences

- LP size: on 2026-06-03T15:00 the VIC1/NEM tie groups add 10,899 rows and 21,798 slack columns to
  a model of 58,000 variables; 2026-06-09T15:00 adds 10,947 and 2026-06-12T23:55 adds 10,568. A
  warm replay (build and solve) takes 80 to 110 s.
- Replay of DUNDWF1/2/3 (published 84/23/61), with referred prices rounded to cents:

  | interval | fraction rows, 8.3e-8 | MW rows, this decision |
  | --- | --- | --- |
  | 2026-06-03T15:00 | 66.2 / 28.7 / 73.1 | 84 / 23 / 61 |
  | 2026-06-09T15:00 | 55.0 / 32.0 / 81.0 | 84 / 23 / 61 |
  | 2026-06-12T23:55 | 32.4 / 43.1 / 92.5 | 84 / 23 / 61 |

  The cent rounding of referred prices makes all floor-priced bands tie exactly, which enlarges
  the tie group to 36 bands; by itself it does not restore the splits. Regional prices are
  unchanged by the rows (VIC1 -2.23, -2.29 and -12.1 with and without them).
- A feasible tie adds zero cost. Prices that differ by less than the tolerance still have an
  economic effect when the saved cost exceeds the slack penalty, so a band 0.5e-6 dearer is simply
  not dispatched. Bid prices are cents, so this does not arise in real data.
- When a tied band is held back its rows are violated and the balance dual can carry the
  penalty, below 1e-6 $/MWh in the toy tests. The slacks are registered PSI keys but are not
  written to results; violated rows are read from the container.
- The 2026-06-09 TAS1 LOWERREG price moved by +1.0 in an earlier run (3.08 with the tie-break
  against 2.08 without, published 1.56): a degenerate-dual sensitivity to re-check against the
  corrected scaling.
- **Service placement.** A template without the `TieBreakMarket` service model (hand-built, or
  `set_nem_dispatch_models!(...; tie_breaks = false)`), or a system on which
  `set_tie_break_scales!` was never called, gets arbitrary tie vertices. Bid blocks created by
  another service model's model stage after this one would not be tied; none exist today.
- The replication optimizer sets zero MIP gaps (`mip_rel_gap = 0`, `mip_abs_gap = 1e-10`). Any
  other optimizer with default gaps and binary variables present may stop before the tie penalty
  is resolved.
- The tied pairs are fixed at build, from the offer prices. A recurrent (`Simulation`) build is
  supported when the pairs stay the same over the range (`check_tie_break_pairs`); the scales
  follow the offers per step. The replication path may also rebuild per interval.
- Not tested by a solve: two regions with equal prices staying separate (the toy has one area).
  The grouping key includes the region.
- A fixed-curve unit in a direction where no unit has a time-varying curve gets no scale from
  `set_tie_break_scales!` (there is no stamp grid to put it on). If its bands tie, the build fails
  with an error naming that cause, rather than leaving the tie unbroken.
- A contributor excluded by its device model's `"filter_function"` (as
  `set_nem_dispatch_models!(...; skip_uncovered = true)` installs) is treated as PSI treats it: not
  modelled, and exempt from the "unmodelled unit carrying scales" check. The pro-rata split of the
  modelled bands is unchanged, since a row's ratio `w_b / w_a` does not depend on `w_ref`.
- `TieBreakMarket` registers no duals; a `ServiceModel` requesting them fails the build by name.

## Follow-ups

- Call `check_tie_break_pairs` from the multi-step `Simulation` path, so a recurrent build whose
  tied pairs change over its range (across a trading day) fails rather than writing the new day's
  scales onto the old pairs. Deferred to the replay core PR, which introduces that path.
- Test that the scales follow the offers across a `Simulation` step (the `TieBreakScaleParameter`
  update). Deferred to the replay core PR with the multi-step path.
- The constraint container is built as the dense `labels x pairs x time_steps` product and then
  filtered to the rows; building it from the row keys would avoid the allocation for large tie
  groups.
