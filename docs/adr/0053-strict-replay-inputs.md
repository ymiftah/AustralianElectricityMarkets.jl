# 0053. Historical dispatch requires complete inputs

## Status

Accepted.

## Context

A January 2026 replay had no MNSP offers in the requested interval. The offer setter warned and
continued with a free-flowing Basslink, changing its costs, limits and loss allocation. Restoring
the offers removed the largest Tasmania price and transfer discrepancies. A completed solve is
not evidence of a complete reconstruction when missing input selects another formulation.

## Decision

Replay fails before model construction, with a named error, when an input it depends on is
missing or only partly usable:

- MNSP status comes from effective-dated `INTERCONNECTORCONSTRAINT.ICTYPE`, independently of
  whether an offer query returns rows; an MNSP needs two registered directional links, their
  terminal factors and complete interval offers (`set_mnsp_offers!`).
- Energy-bid coverage is checked independently of price joins: every scheduled unit that is
  available or metered needs an energy offer for every interval, and every region with a unit
  needs regional demand for every interval.
- `replication_template` rejects dispatch constraint intervals missing from the cache, skipped
  constraint definitions, dropped unit terms, constraints given a default penalty weight and
  devices missing a dispatch-limit series.
- Participant fixed-load constraints are built from the submitted `FIXEDLOAD` inputs, with penalty
  factor 380 (AEMO CVP item 13), rather than left out because their published dispatch rows have no
  `GENCONDATA` version.

## Sources

- AEMO Electricity Data Model Report v5.7.0, `INTERCONNECTORCONSTRAINT` (`ICTYPE` identifies
  REGULATED versus MNSP, selected by effective date and version), `MNSP_INTERCONNECTOR` (link
  endpoints and terminal loss factors), `MNSP_DAYOFFER`, `MNSP_BIDOFFERPERIOD` and
  `DISPATCH_MNSPBIDTRK` (submitted bands and the offer selected for each interval).
- AEMO Schedule of Constraint Violation Penalty Factors v8.0, item 13: participant fixed loading
  is a unit equality with penalty factor 380.

## Consequences

Existing incomplete caches and systems fail with named input errors before a solve. The error is
resolved by supplying the missing data or implementing the unsupported equation, not by relaxing
the completeness check. The reader fixtures keep deliberately invalid constraints; the replay
fixture (`create_mock_data(...; complete_inputs = true)`) invokes only complete equations.
