# 0053. Historical dispatch requires complete inputs

## Status

Accepted.

## Context

A January 2026 replay had no MNSP offers in the requested interval. The offer setter warned and
continued with a free-flowing Basslink, changing its costs, limits and loss allocation. Restoring
the offers removed the largest Tasmania price and transfer discrepancies. A completed solve is
not evidence of a complete reconstruction when missing input selects another formulation.

## Decision

Resolve MNSP status from effective-dated INTERCONNECTORCONSTRAINT.ICTYPE, independently of whether
an offer query happens to return rows. Require two registered directional links, their terminal
factors and complete interval offers. Validate every link before replacing any attached series.
Reject missing, non-finite and invalid quantities and prices. Regulated interconnectors need no
MNSP offers. Reject a range crossing a change in classification.

Replay checks energy-bid coverage independently of price joins and requires regional demand
for every effective-dated unit registration. A region absent from all demand data must not
disappear through the demand-derived system topology. Replay also rejects skipped constraint
definitions, dropped terms, defaulted penalty weights and missing dispatch-limit series. It uses
strict template coverage checks. Participant fixed-load
constraints are built from submitted energy FIXEDLOAD inputs rather than omitted because their
published dispatch rows have no GENCONDATA version. Their factor is 380, following AEMO CVP item 13.
The existing fixed-load implementation excludes units offering a fast-start profile; strict replay
rejects an invoked fixed-load constraint left unresolved by that limitation.

## Sources

- AEMO Electricity Data Model Report v5.7.0, INTERCONNECTORCONSTRAINT, pp. 404-406:
  ICTYPE identifies REGULATED versus MNSP, selected by effective date and version.
- MNSP_INTERCONNECTOR, pp. 517-518: link endpoints and terminal loss factors.
- MNSP_DAYOFFER, pp. 69-71, MNSP_BIDOFFERPERIOD and DISPATCH_MNSPBIDTRK:
  submitted bands, quantities and the offer selected for each dispatch interval.
- AEMO Schedule of Constraint Violation Penalty Factors v8.0, pp. 13-17, item 13:
  participant fixed loading is a unit equality with penalty factor 380.

## Consequences

Existing incomplete caches and systems fail with named input errors before a solve. The error
must be resolved by supplying the missing data or implementing the unsupported equation, rather
than relaxing the completeness check. Reader fixtures retain deliberately invalid constraints;
replay fixtures invoke only complete equations.

## Validation

The populated primary cache was replayed for all 288 intervals from 2026-01-01 04:05 to
2026-01-02 04:00 AEST, using Julia 1.13.1 and the pinned solver dependencies. The three MNSP
submission/tracking tables were populated for December 2025 and January 2026. The replay used
all default formulation parts, `interval_flow_limits = false`, `mip_rel_gap = 0.0` and
`mip_abs_gap = 1e-10`.

All 288 intervals terminated optimally. No missing constraint definitions or terms were skipped.
Three template eliminations concerned unavailable wholesale demand response devices. All 9,504
unmodelled dispatch rows, across 33 DUIDs, had zero published targets. BLOWERNG matched its published
dispatch exactly; HUMENSW's largest absolute gap was 0.0000038 MW after adding its fixed loading.

| Metric | Original replay | Complete-input replay |
| --- | ---: | ---: |
| Regional ROP mean absolute error (AUD/MWh) | 10.590333 | 0.302533 |
| FCAS ROP mean absolute error, all regions (AUD/MWh) | 0.486194 | 0.007738 |
| Interconnector flow mean absolute error (MW) | 41.776653 | 1.520848 |
| Interconnector loss mean absolute error (MW) | 2.926460 | 0.129269 |
| Modelled dispatch rows within 1 MW | 97.3717% | 99.0671% |

At the original worst Tasmania interval, 2026-01-01 13:10 AEST, the corrected ROP was
51.310184 AUD/MWh against the published 51.310180. Basslink flow was -180.85688 MW against
-180.86122 MW.

### Regional price distribution

Errors below use our resolved ROP minus NEMDE's published ROP. Percentiles use absolute errors,
and all monetary values are AUD/MWh. Each region has 288 observations; every region's median
absolute error is below 0.0001 AUD/MWh.

| Region | Mean bias | Mean absolute error | 95th percentile | 99th percentile | Maximum absolute error | Within 1 AUD/MWh |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| NSW1 | +0.003865 | 0.051458 | 0.234166 | 1.404993 | 3.342100 | 97.9167% |
| QLD1 | +0.589810 | 0.646318 | 0.006686 | 7.983570 | 70.230000 | 96.5278% |
| VIC1 | +0.175233 | 0.233037 | 1.266324 | 4.739611 | 9.350000 | 93.7500% |
| SA1 | +0.295917 | 0.382648 | 1.621926 | 8.992979 | 15.436765 | 92.7083% |
| TAS1 | +0.135341 | 0.199202 | 0.400514 | 6.967366 | 9.637265 | 96.1806% |

Queensland's three largest errors, 41.04, 62.8052 and 70.23 AUD/MWh, account for 93.52% of its
summed absolute error. South Australia has more frequent small discrepancies: 61.81% of its
intervals match within 0.01 AUD/MWh, compared with 83.68% to 95.14% in the other regions.

### Runtime and checks

Execution took 3,655.15 seconds, or 12.69 seconds per interval on average. Initial system and model
construction took 102.06 and 153.74 seconds respectively. Construction plus execution therefore
took 65.18 minutes, or 13.58 seconds per interval amortised across the day. Comparison and report
generation are separate.

The average optimisation call took 8.72 seconds and the pricing/dual pass 1.99 seconds. Together
these stages accounted for approximately 84% of execution time. Interval event durations had a
median of 8.30 seconds, a 90th percentile of 25.42 seconds and a maximum of 52.70 seconds.

Local checks covered the root suite (1,604 assertions), Simulations suite (2,958 assertions),
final input-completeness regressions (15 assertions), and demand setters (477 assertions).
Runic, Markdown lint and `git diff --check` passed. The full-day run's source patch matched at
launch and completion.

Raw results and the source patch are retained under
`/run/media/simba/Store/aem_validation/stock_sim/strict_inputs_20261017_v3`.
The before/after comparison uses the original `stock_sim/nemde_compare/n288` output.

### Remaining formulation differences

The maximum price gap remains 70.23 AUD/MWh. PUMP1 at 06:20 and PUMP2 at 06:35 dispatch at 244 MW
while their published targets are zero, consistent with the missing fast-start profile treatment
on this branch. Snowtown's non-conformance targets can exceed the hard UIGF bounds used here;
NEMDE's separate violation priorities permit a different result. These are remaining formulation
limitations after restoring the missing inputs.
