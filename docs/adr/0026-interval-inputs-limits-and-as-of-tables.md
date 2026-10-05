# 0026. Per-interval interconnector limits and as-of static tables

## Status

Accepted

## Context

The replication path took interconnector flow bounds from the newest `INTERCONNECTORCONSTRAINT`
version (static `MAXMWIN`/`MAXMWOUT`) and unit loss factors from the newest `DUDETAILSUMMARY`
row. For June 2026 data the newest rows are the FY26-27 versions effective 2026-07-01 (for
example MURRAY MLF 0.9565 where 0.9819 was in force), so static inputs came from the wrong
period, and the energy limits NEMDE applied each interval (`DISPATCHINTERCONNECTORRES`
`EXPORTLIMIT`/`IMPORTLIMIT`) were unused.

## Decision

- **Applied limits as bounds.** `set_interconnector_flow_limits!` attaches `IMPORTLIMIT` and
  `EXPORTLIMIT` as the `"from_to_flow_limit"` and `"to_from_flow_limit"` series the
  `NEMInterconnectorLoss` flow-limit constraint already reads, so `IMPORTLIMIT <= flow <=
  EXPORTLIMIT` along the from-to direction (AEMO MMS Data Model, `DISPATCHINTERCONNECTORRES`:
  positive flow starts at the from-region; both limits are signed). The series is the limit as a
  fraction of the static limit, which stays the outer envelope. A missing row, a `NULL` limit or
  crossed limits fall back to the static limit with one warning. `replication_system` calls it;
  other builds keep the static limits.
- **Outputs used as inputs.** `EXPORTLIMIT`/`IMPORTLIMIT` are NEMDE results ("calculated"
  limits derived from the invoked generic constraints named by `EXPORTGENCONID` and
  `IMPORTGENCONID`), not inputs AEMO publishes. Using them is the same convention as taking
  `DISPATCHCONSTRAINT.RHS` for constraint right-hand sides, which nempy also does. It
  double-counts nothing: the generic constraints that set the limits are enforced as
  constraints too, so the bound is redundant with them where they are modelled and a safety
  net where a constraint is skipped. It must not be used to validate the model's flows against
  the published limits, since the bound pins them. `FCASEXPORTLIMIT`/`FCASIMPORTLIMIT` (energy
  plus FCAS) are not used.
- **Initial flow.** `METEREDMWFLOW` is the flow at the start of the interval; `MWFLOW` is the
  target NEMDE chose. Both are read (`read_interconnector_limits` returns `METEREDMWFLOW`), but
  nothing consumes the metered flow: it is the ramp base of MNSP links, which are not modelled
  per link yet. `IntervalInputs.interconnector_flows` holds the target `MWFLOW`.
- **As-of resolution.** `read_interconnectors` and `read_units` take `as_of`: the latest
  `INTERCONNECTORCONSTRAINT` row with `EFFECTIVEDATE <= as_of` (then highest `VERSIONNO`), the
  `DUDETAIL` row likewise, and the `DUDETAILSUMMARY` row with `START_DATE <= as_of < END_DATE`
  (loss factors are published per financial year with a 1 July start; see the Marginal Loss
  Factors reports). Units absent as of the date drop out. `as_of = nothing` keeps the previous
  latest-version behaviour. `nem_system` accepts `as_of`; `ConstrainedNetworkConfiguration`
  defaults it to the start of `date_range`, while `RegionalNetworkConfiguration` keeps the latest
  version because it has no date range.

## Consequences

- A constrained build now differs from before whenever a static table gained a newer version
  after `date_range`'s start. Pass `as_of = nothing` to restore the latest version.
- Interconnector region pairs still come from the newest `INTERCONNECTOR` partition: they do not
  change over time for active interconnectors.
- Basslink changed type (MNSP to regulated in the newest version); as-of resolution removes the
  mismatch between its limits and its loss parameters, but its per-link offers remain unmodelled.
