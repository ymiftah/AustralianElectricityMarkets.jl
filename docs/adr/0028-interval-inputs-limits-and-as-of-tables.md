# 0028 Interconnector limits and as-of static tables

## Status

Accepted

## What

- Static tables resolve as of the run start, not the newest cached version. For June 2026 data the newest rows are the FY26-27 versions effective 2026-07-01 (MURRAY MLF 0.9565 where 0.9819 was in force).
- Per-interval published flow limits are opt-in and a diagnostic only.

## How

- `read_interconnectors` and `read_units` take `as_of`; `nem_system` passes `first(date_range)`. Only the latest monthly archive is read (each holds the full history; older ones carry superseded rows). Within it:
  - `INTERCONNECTORCONSTRAINT` and `DUDETAIL`: the latest row with `EFFECTIVEDATE <= as_of`, then highest `VERSIONNO`.
  - `DUDETAILSUMMARY`: the row in force at the date (loss factors are published per financial year from 1 July; see the Marginal Loss Factors reports).
  - `AUTHORISEDDATE` is ignored. `as_of = nothing` keeps the latest version.
- Interconnector region pairs still come from the newest `INTERCONNECTOR` partition: they do not change for active interconnectors.
- `set_interconnector_flow_limits!` (called when `nem_system` gets `interval_flow_limits = true`, default `false`) bounds flow by `DISPATCHINTERCONNECTORRES` `IMPORTLIMIT` / `EXPORTLIMIT`, as the `"from_to_flow_limit"` / `"to_from_flow_limit"` series `NEMInterconnectorLoss` reads. The lower bound is the smaller signed limit, the upper the larger, each clamped into `[-MAXMWIN, MAXMWOUT]`. `FCASEXPORTLIMIT` / `FCASIMPORTLIMIT` are not used.
- `METEREDMWFLOW` is the flow at the start of the interval (initial flow); `MWFLOW` is the target NEMDE chose.

## Why

- AEMO computes the published limits after the solve (each binding constraint's right-hand side projected with the other terms held at NEMDE's solved values), so they are results. As hard bounds they pin flows to NEMDE's answer and can conflict with elastic generic constraint rows. Use them only to isolate flow gaps, never when validating flows. This differs from taking `DISPATCHCONSTRAINT.RHS` as a constraint right-hand side, which is a data input.
- Basslink changed type (MNSP to regulated) in the newest version; as-of resolution keeps its limits and loss parameters from the same period.

## Open

- `INTERCONNECTORCONSTRAINT` carries static `IMPORTLIMIT` / `EXPORTLIMIT`, which nempy uses in place of `MAXMWIN` / `MAXMWOUT`. In the 2026-07-01 version they are 1 MW below them for every active interconnector (VIC1-NSW1 2300/2400 against 2299/2399). Whether the 1 MW matters is unchecked; the default is unchanged.
