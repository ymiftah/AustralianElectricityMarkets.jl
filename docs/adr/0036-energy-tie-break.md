# 0036 Price-tied energy bands clear pro rata, with elastic links

## Status

Accepted. `EnergyTieBreak` lives in the top-level package and its scales are written by `nem_system` ([0101](0101-aem-writes-aemsim-reads.md)).

## What

- When energy bands of different units are price-tied and the group is marginal, NEMDE dispatches them in proportion to band MW through a tie-break constraint per pair of tied bands (Constraint FAQ 3.19; energy only, not FCAS).
- Item 53 of the CVP Schedule gives the slacks `TBSlack1` and `TBSlack2` a factor of 1e-6, and defines tied as prices "adjusted by intra-regional loss factors" within 1e-6, per region and bid type.
- Without the rows HiGHS returns an arbitrary vertex (DUNDWF1/2/3 tied at -984.5 under a 168 MW limit: published 84/23/61, replica 100/0/68).

## How

- A PSI service model `ServiceModel(EnergyTieBreak, TieBreakMarket, "energy_tie_break")`. Its model stage runs after every device's bid objective, reads the `EnergyOfferBandVariable`s, so it crosses device types (wind against solar) and works under any network model. The argument stage is a no-op. `set_nem_dispatch_models!` registers it unless `tie_breaks = false`.
- Detection per (direction, region, time step): offer and load-bid bands are separate groups, priced at the referred offer prices ([0033](0033-energy-bids-referred-to-reference-node.md)); sorted prices group while consecutive ones differ by at most 1e-6 (transitive). Bands empty at every timestamp are skipped; same-unit pairs are excluded.
- Every pair of bands `a`, `b` of different units in a group gets `(x_a w_b - x_b w_a) / w_ref + up - down = 0`: `x` cleared MW, `w` band width, `w_ref` the widest band of the group. Rows are built with unit placeholders; the scale `w / w_ref` is a `TieBreakScaleParameter` read from each unit's `"tie_break_scale_<k>"` series.
- `TieBreakSlackUp`/`TieBreakSlackDown` are priced at `TIE_BREAK_CVP_FACTOR` (1e-6 $/MWh) times base power and interval hours, not scaled by the Market Price Cap. Rows are `TieBreakConstraint`, keyed by `EnergyTieBreak` with the service name as meta.
- No container is added when nothing ties, because PSI's MILP dual pass cannot read an empty variable container. The tied pairs are fixed at build from each modelled time step's prices; only the scales update per step.
- A tied band with no scale series, or an unmodelled contributor carrying one, fails the build by name; a contributor excluded by its device model's `"filter_function"` is exempt. `TieBreakMarket` registers no duals.

## Why

- Constraints, not a price perturbation: AEMO and nempy both use equality rows, and a perturbation picks a vertex again.
- Elastic, as AEMO and nempy: a band held back by a ramp, availability or group limit relaxes its rows.
- All pairs, not a chain or hub: a chain depends on DUID order once a band is held back, and a hub leaves a limited subset filling its narrowest band first (nempy and FAQ 3.19 are per pair).
- MW rows rather than nempy's fill-fraction rows `x_a/w_a - x_b/w_b = 0`: the same equality when feasible, but when rows are violated the fraction form costs `1/w_i` per MW of band `i`, so a group-limited subset loads its narrowest band first. The MW form costs `w_k / w_ref` against band `k` whatever `i` is, so the split is set by the subset's own rows.
- Slack in per-unit MW because a fraction slack at 1e-6 per hour (8.3e-8) is below HiGHS' dual feasibility tolerance (1e-7) and is treated as free; per-unit MW gives 8.3e-6. Tightening the tolerance does not help. This departs from AEMO's absolute unit, which the schedule does not state.

## Consequences

- Without the service model (hand-built template, `tie_breaks = false`) ties resolve arbitrarily, as with any optimizer whose MIP gap is too loose to resolve the penalty.
