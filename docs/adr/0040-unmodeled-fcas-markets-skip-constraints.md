# 0040. Constraints with terms on unmodelled FCAS markets are not built

## Status

Superseded by 0041. The guard it added was the interim fix; once `RAISE1SEC`/`LOWER1SEC` joined
`FCAS_BID_TYPES` no `BidType` is left outside the modelled set, so the guard was removed.

## Context

`FCAS_BID_TYPES` holds the eight modelled FCAS markets, so `add_fcas_services!` never creates a
`RAISE1SEC`/`LOWER1SEC` `FCASService`, and `read_fcas_requirements` drops the 1-second requirement
rows. The generic constraints that carry 1-second terms (`F_*_R1`, `F_*_L1`, for example
`F_MAIN++NIL_MG_R1`, `F_I+BIP_ML_L1`, `F_Q+BCDM_L1`) were nevertheless built. Their 1-second
`RegionTerm`/`UnitTerm`s contributed zero, because a service absent from the System contributes
zero by design (0024). What remained was the region and interconnector part of a `>=` requirement
row with no 1-second capacity to meet it, so the row was violated in every interval and priced at
its constraint violation penalty. `F_MAIN++NIL_MG_R1` carries `InterconnectorTerm("T-V-MNSP1", -1.0)`,
so each MW of Basslink import reduced the violation by the penalty rate (1.5225e6 per MW), swamping
the 77 to 104 $/MWh offers and forcing the import until another hard row capped it. This caused the
TAS1 price gaps on 2026-06-04, 2026-06-09 and 2026-06-13.

The pre-flight check already reported `:unmodeled_fcas_service`, but only for a service that exists
in the System with devices and no `FCASMarket` model. A market that has no service at all fell
through the "absent service is zero" rule.

## Decision

`filter_buildable_generic_constraints` treats any `UnitTerm`/`RegionTerm` whose `bid_type` is an
FCAS market outside `FCAS_BID_TYPES` as `:unmodeled_fcas_service`, whether or not devices carry the
service. The check is on the term, ahead of the device lookup. A constraint with such a term is
reported (and skipped under `allow_partial_coverage = true`, as the replication template does)
instead of being built as an always-violated row.

Absent services within the modelled markets keep their zero contribution: a region where nobody
bid RAISE5MIN genuinely has no enablement, and the constraint is satisfiable in the model's terms.

## Consequences

- The R1/L1 requirement rows stop pricing at the penalty, so the Basslink import is no longer
  pulled by a spurious 1.5e6 $/MW gradient.
- Those constraints are absent from the replica, so 1-second requirement prices are not produced
  until the markets are modelled.
- Skipping rather than building also drops any non-1-second terms the constraint carries; this is
  preferred to a partial row whose RHS is AEMO's full solved value.
