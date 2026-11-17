# NEMDE conformance register

## Status

Living reference (not an ADR), reviewed 2026-11-16 against the code and ADRs of this branch.

This is a living register of where the NEM dispatch run follows or departs from AEMO's published NEMDE rules. It replaces the October 2026 documentation-gap audit, whose findings are resolved in the formulation chapters under `docs/literate/formulation/`. Each row cites the ADR that holds the detail. Constants were checked against `src/system/penalties.jl`; AEMO text is as cited by the ADRs and was not re-read, so rows marked `unverified` rest on an ADR alone. Any new departure goes in an ADR and here.

## Objective and penalties

Sources for CVP factors: AEMO *Schedule of Constraint Violation Penalty Factors* v8.0, Table 1. Every elastic row costs `factor x Market Price Cap` ([0085](0085-build-time-market-price-cap.md), [0071](0071-objective-only-penalty-and-band-costs.md)).

| AEMO requirement | Implemented in | Status |
| --- | --- | --- |
| Unit ramp rate, item 3, 1155 | [0030](0030-elastic-unit-ramp-rows.md), [0068](0068-device-rows-always-elastic.md) | Follows |
| Total band MW offer, item 8, 1135 | [0064](0064-elastic-energy-offer-totals.md) | Follows; over-constrained pricing rerun not reproduced |
| Unit MaxAvail 370 (item 14) and UIGF 385 (item 12) are soft | [0062](0062-elastic-energy-limits.md), [0063](0063-elastic-storage-availability.md) | Follows; no hard availability ceiling |
| Interconnector capacity, item 5, 1150; loss breakpoint range has no penalty item | [0037](0037-elastic-rows-remaining-families.md) | Follows; the breakpoint range stays a hard bound |
| FCAS MaxAvail 155 (19), joint ramping 155 (20), BDU ramping 155 (21), enablement 70 (24) | [0023](0023-elastic-fcas-rows-and-area-balance-cvp.md), [0037](0037-elastic-rows-remaining-families.md) | Follows when the `FCASMarket` model has `use_slacks = true`; otherwise MaxAvail is a variable bound |
| Regional balance 150 (items 22, 23); enablement is violated before balance | [0023](0023-elastic-fcas-rows-and-area-balance-cvp.md) | Follows |
| Generic constraints, factor from `GENERICCONSTRAINTWEIGHT`; non-invoked constraint absent | [0021](0021-elastic-generic-constraints.md), [0101](0101-aem-writes-aemsim-reads.md) | Follows; a NULL weight is read as 1.0 |
| Energy inflexible offer 380 (13), MNSP offer 1135 (9), availability 365 (16), ramp 1155 (4) | [0076](0076-mnsp-operating-limits.md) | Follows |
| Unit and interconnector zero constraints, item 1, 1160 | [0039](0039-interconnector-zero-constraints.md) | Follows |
| Fast-start inflexibility profile, item 10, 1130 | [0106](0106-fast-start-two-run-dispatch.md) | Follows |
| Energy tie-break slack factor 1e-6, item 53 | [0036](0036-energy-tie-break.md) | Follows; not scaled by the Market Price Cap |

## Energy, bids and units

| AEMO requirement | Implemented in | Status |
| --- | --- | --- |
| Offer prices referred to the regional reference node by loss factor | [0033](0033-energy-bids-referred-to-reference-node.md) | Follows; which side of 1 July NEMDE uses is `unverified` |
| Band prices fixed per trading day, MW per interval | [0101](0101-aem-writes-aemsim-reads.md) | Follows |
| Battery as one bidirectional unit, no state of charge in dispatch | [0020](0020-batteries-under-nem-dispatch.md), [0063](0063-elastic-storage-availability.md) | Follows; no charge/discharge exclusivity, as NEMDE is one LP |
| Split-battery generator and load halves dispatched as separate units | [0105](0105-split-battery-units-and-unregistered-terms.md) | Follows |
| Scheduled and ancillary loads, WDR | [0032](0032-scheduled-loads-and-unresolved-constraint-terms.md), [0038](0038-load-fcas-offers.md) | WDR dispatch not modelled |
| Energy tie-break among price-tied bands, in proportion to band MW | [0036](0036-energy-tie-break.md) | Follows; pairs fixed at build |
| Generic-constraint RHS as NEMDE enforced it | [0003](0003-no-dynamic-rhs.md) | Runs `DISPATCHCONSTRAINT.RHS`; the RHS engine is not re-implemented |
| Constraint terms on units absent from the System | [0032](0032-scheduled-loads-and-unresolved-constraint-terms.md), [0104](0104-vacuous-constraints-on-retired-units.md), [0105](0105-split-battery-units-and-unregistered-terms.md) | Dropped terms of registered units fail; unregistered or vacuous ones are allowed |

## FCAS

| AEMO requirement (*FCAS Model in NEMDE* v3.0) | Implemented in | Status |
| --- | --- | --- |
| Trapezium scaling s4.1 to s4.3 | [0018](0018-fcas-trapezium-scaling.md) | Follows; scaling inputs are not attached to scheduled loads, so their regulation trapezium is used as bid |
| Joint capacity rows s6.2, s6.3; contingency rows include regulation targets | [0017](0017-fcas-market-formulation.md) | Follows |
| Joint ramping s6.1 and BDU ramping s6.4; fast-start exemption, Table 3 footnote | [0017](0017-fcas-market-formulation.md), [0106](0106-fast-start-two-run-dispatch.md) | Follows; run 2 keeps run 1's exemption (departs from nempy) |
| AGC ramp rate is the telemetered rate | [0087](0087-agc-ramp-rate-from-mmsdm.md) | Departure: a derived lower bound, so joint ramping can be tighter than NEMDE |
| s5 pre-conditions (availability, enablement, sign, stranding) | [0017](0017-fcas-market-formulation.md) | Follows; daily and profiled energy tests are not implemented (`unverified`) |
| Loads swap regulation sides | [0038](0038-load-fcas-offers.md) | Follows AEMO; departs from nempy's ramp row |
| Prices are the duals of the requirement constraints | [0024](0024-fcas-terms-in-generic-constraints.md) | Follows |
| Very fast markets from 9 October 2023 | [0041](0041-one-second-fcas-markets.md) | Follows |

## Interconnectors and losses

| AEMO requirement | Implemented in | Status |
| --- | --- | --- |
| Quadratic loss linearised on `LOSSMODEL` breakpoints, split by `FROMREGIONLOSSSHARE` | [0022](0022-interconnector-loss-formulation.md), [0031](0031-interconnector-loss-contiguous-segment-fill.md) | Follows; segment-order binaries make this a MILP, with prices from the fixed-integer LP |
| Loss equation at region demand | [0027](0027-loss-equation-regional-demand.md) | `LOSSDEMAND` is taken from NEMDE case files; no AEMO document states it (`unverified` against AEMO text) |
| Missing loss inputs, V-SA NSW term, Basslink share 1.0 | [0091](0091-interconnector-loss-input-assumptions.md) | Reconstructions, not AEMO values |
| MNSP directional offers | [0035](0035-mnsp-link-offers.md), [0076](0076-mnsp-operating-limits.md) | Follows; the direction binary is always imposed; Basslink converter loss and no-go zone are `unverified` |

## Solver and prices

| Topic | Implemented in | Status |
| --- | --- | --- |
| Tied optima resolved by AEMO's solver path | [0094](0094-highs-root-heuristics-and-tied-vertices.md), [0101](0101-aem-writes-aemsim-reads.md) | Not reproducible; prices at degenerate vertices can differ, so comparison gates use invariants |
| Administered price adjustments (`RRP` against `ROP`) | none | Not modelled (`unverified`); run compares unadjusted prices |
