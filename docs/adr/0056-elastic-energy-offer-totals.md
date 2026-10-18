# 0056. Price violations of total offered energy bands

## Status

Accepted.

## Problem

The market-bid path requires dispatch to equal the sum of cleared bounded price bands. This
makes total offered energy MW an immutable limit, while NEMDE can violate that limit when
higher-priority constraints require it.

## Sources

AEMO's Schedule of Constraint Violation Penalty Factors v8.0, effective 2 December 2025,
Table 1 item 8, p. 11, assigns CVP1135 to Total Band MW Offer constraints using
DeficitOfferMW and SurplusOfferMW. Non-conformance (item 2, p. 7) and unit ramping
(item 3, p. 7) have higher individual priorities; MaxAvail (item 14, p. 14) is CVP370.
The sum of violation costs, rather than a lexicographic selection of one constraint, governs
conflicts involving multiple limits.

Official source:
<https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf>

The nem-expert extracts are
`references/constraint-violation-penalty-factors/03-items-01-11.md`, pp. 6-12, and
`04-items-12-21.md`, pp. 13-17. The existing per-band bounds and prices are taken from
BIDPEROFFER_D and BIDDAYOFFER_D, Electricity Data Model Report v5.7.0, pp. 62-67.

## Decision

Retain each offered band variable, its quantity bound, and its existing bid cost. Replace
only the link to dispatch for AbstractNEMDispatch:

```text
dispatch = sum(cleared_band_MW) + above_offer_slack - below_offer_slack
above_offer_slack >= 0
below_offer_slack >= 0
```

Each slack costs CVP1135 times MPC, system base power and interval hours. Violation MW
has no invented offer price beyond the submitted bands. Existing band costs apply only to
cleared offered quantities. Separate registered containers identify generation and consumption
offer directions. Reporting uses the `energy_offer` family and the sense of the relaxed
dispatch-to-band link.

The override is restricted to the pinned PSI market-bid constraint hook for NEM dispatch.
Other PSI formulations, FCAS bands, MNSP offers and tie-break bands are unaffected. Width
constraints retain live PSI breakpoint parameters, so recurrent interval updates do not
freeze the initial offer quantities. No artificial extra band or numerical capacity is added.

## Scope

This resolves the total-band departure recorded in 0054. Storage availability is a separate
change. A dispatch exceeding both availability and offered bands must pay both penalties.
Real-time replay remains independent by interval. These changes do not reproduce AEMO's
over-constrained pricing rerun procedure.

## Validation

The full Simulations suite passed 3,073 assertions across 16 groups. The root suite
passed 1,624 assertions. A temporary checkout combining the storage and
total-offer changes passed 152 assertions across the energy-limit, storage-availability and
total-offer groups, plus 10 assertions checking cumulative storage penalties. Availability
and total-offer violations retain separate costs when they are both required.

Regression cases cover zero offered quantity, both storage directions, scheduled loads,
nonzero first breakpoints, and recurrent widths in either interval order. Result containers
include only devices with the corresponding offer direction, so a device model can also
contain FCAS-only units without leaving uninitialised result entries.

Independent fresh-process cached replays of 2 January 2026 02:00 and 1 January 2026 04:55
AEST retained all four Snowtown targets within 1e-8 MW. All four dispatch/pricing calls were
optimal and passed primal-residual and objective-consistency audits. These two intervals do
not establish full-day equivalence. An initial replay attempted after the full suite in the
same Julia process returned HiGHS OTHER_ERROR; the full suite itself passed. The fresh-process
replay used the same mathematical formulation and solver settings and passed.

Reproducible result CSVs, audit scripts, environments, logs and source patches are archived at
`/run/media/simba/Store/aem_validation/stock_sim/elastic_dispatch_violations_20261018`.
