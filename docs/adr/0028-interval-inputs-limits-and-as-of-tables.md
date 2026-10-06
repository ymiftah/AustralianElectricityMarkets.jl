# 0028. Interconnector limits and as-of static tables

## Status

Accepted

## Context

The replication path took interconnector flow bounds from the newest `INTERCONNECTORCONSTRAINT`
version (static `MAXMWIN`/`MAXMWOUT`) and unit loss factors from the newest `DUDETAILSUMMARY`
row. For June 2026 data the newest rows are the FY26-27 versions effective 2026-07-01 (for
example MURRAY MLF 0.9565 where 0.9819 was in force), so static inputs came from the wrong
period.

## Decision

- **As-of resolution.** `read_interconnectors` and `read_units` take `as_of`. Each monthly
  archive holds the full history, so only the latest archive is read (older archives carry stale
  rows that the latest one has since closed or superseded). Within it, the latest
  `INTERCONNECTORCONSTRAINT` row with `EFFECTIVEDATE <= as_of` (then highest `VERSIONNO`), the
  `DUDETAIL` row likewise, and the `DUDETAILSUMMARY` row with `START_DATE <= as_of < END_DATE`
  (loss factors are published per financial year with a 1 July start; see the Marginal Loss
  Factors reports). `AUTHORISEDDATE` is ignored: a version is selected by its effective date, not
  by when it was authorised. Units registered now but not in force as of the date drop out with a
  warning. `as_of = nothing` keeps the previous latest-version behaviour. `nem_system` accepts
  `as_of`; `ConstrainedNetworkConfiguration` defaults it to the start of `date_range`, while
  `RegionalNetworkConfiguration` keeps the latest version because it has no date range.
- **Per-interval limits are opt-in and a diagnostic.** `set_interconnector_flow_limits!` bounds
  flow by the `DISPATCHINTERCONNECTORRES` `IMPORTLIMIT` and `EXPORTLIMIT` through the
  `"from_to_flow_limit"` and `"to_from_flow_limit"` series `NEMInterconnectorLoss` reads. AEMO
  computes these limits after the solve (each binding constraint's right-hand side projected with
  the other terms held at NEMDE's solved values), so they are results, not inputs. Using them as
  hard bounds pins flows to NEMDE's answer and can conflict with generic constraint rows that are
  elastic. It is not redundant with those constraints. This differs from taking
  `DISPATCHCONSTRAINT.RHS` as the constraint right-hand side, which fixes a data input rather
  than a solved quantity. `replication_system` and `replicate_interval` therefore take
  `interval_flow_limits = false`; set it to `true` only to isolate flow gaps, never when
  validating flows. The signed limits are ordered (lower = min, upper = max) and each is clamped
  into the static envelope `[-MAXMWIN, MAXMWOUT]`. `FCASEXPORTLIMIT`/`FCASIMPORTLIMIT` are not
  used.
- **Initial flow.** `METEREDMWFLOW` is the flow at the start of the interval; `MWFLOW` is the
  target NEMDE chose. `read_interconnector_limits` returns `METEREDMWFLOW`, but nothing consumes
  it: it is the ramp base of MNSP links, which are not modelled per link yet.
  `IntervalInputs.interconnector_flows` holds the target `MWFLOW`.

## Consequences

- A constrained build differs from before whenever a static table gained a newer version after
  `date_range`'s start. Pass `as_of = nothing` to restore the latest version.
- Interconnector region pairs still come from the newest `INTERCONNECTOR` partition: they do not
  change over time for active interconnectors.
- Basslink changed type (MNSP to regulated in the newest version); as-of resolution removes the
  mismatch between its limits and its loss parameters, but its per-link offers remain unmodelled.

## Follow-up

- `INTERCONNECTORCONSTRAINT` also carries static `IMPORTLIMIT`/`EXPORTLIMIT` (unsigned, whole MW,
  with the import limit negated by nempy), a pre-solve envelope that nempy uses in place of
  `MAXMWIN`/`MAXMWOUT`. In the cache's 2026-07-01 version they are `MAXMWIN`/`MAXMWOUT` minus
  1 MW for every active interconnector (VIC1-NSW1 2300/2400 against 2299/2399, NSW1-QLD1
  2479/2205 against 2478/2204), and the data model gives no semantics beyond "limit". The
  default is unchanged. Whether the 1 MW difference matters is to be checked against published
  limits on a few intervals before switching.
