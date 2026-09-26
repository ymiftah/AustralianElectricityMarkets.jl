# 0009. `FCASService` is a bare `add_service!` anchor, filtered by region + bid presence

## Status

Accepted

## Context

`add_nem_constraints!` already replays AEMO's regional FCAS requirement as the `"rhs"`/
`"invoked"` series on each governing [`GenericConstraint`](@ref) — that is the market's only
arithmetic source of truth. What's still missing is a `PSY.Service` a `PowerSimulations.jl`
extension can `add_service!`-join to sum device-level FCAS enablement variables per `(region,
bid_type)`, the same way `RegionTerm` already does for network terms.

AEMO clears one FCAS price per `(region, bid_type, interval)`, not per unit — so the natural
container key is `(region, bid_type)`, not device. A per-unit service would both misrepresent
the market and multiply template registrations for no benefit; the decision variable a
formulation sums over still lives per `(device, t)`, unchanged.

Which devices join a `(region, bid_type)` service is a question this package can answer today:
region membership (`_region_devices`) and bid-series presence (`set_fcas_bids!`'s
`"fcas_curve_<SERVICE>"`/`"..._decremental"` naming) are both already computed. Whether a
`PowerSimulations.jl` template actually models a given device is not something this package
knows — that's a Phase 2 / `PSI.ProblemTemplate` concept, out of scope here.

## Decision

- `FCASService` carries `region`, `bid_type`, `available`, `ext` — no RHS, no time series
  (`supports_time_series` is `false`).
- `add_fcas_services!(sys)` builds one per `(region, bid_type)` pair drawn from every
  `GenericConstraint.fcas_requirements` in `sys`, attached to every device that is both in
  `region` and carries an incremental or decremental FCAS curve series for `bid_type`.
- A pair with zero contributing devices is skipped and collected into one aggregated `@warn`,
  never thrown — sparse FCAS participation in a region/market is ordinary, unlike an empty
  `RegionTerm` (see `add_nem_constraints!`'s `allow_empty_region_terms`), which signals
  abnormal topology.

## Consequences

- One arithmetic source of truth: a formulation reads the requirement off
  `GenericConstraint`'s `"rhs"` and sums contributing devices via `FCASService`, never both.
- `add_fcas_services!` must run after both `set_fcas_bids!` and `add_nem_constraints!`; wired
  as the third step in `ConstrainedNetworkConfiguration`.
- Device eligibility here is necessarily provisional — a Phase 2 formulation may still exclude
  a device this service includes, if no template models it.
