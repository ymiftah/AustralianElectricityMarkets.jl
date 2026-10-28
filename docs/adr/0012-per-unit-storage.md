# 0012. Per-unit storage for `GenericConstraint`/FCAS/`InterconnectorLossModel`

## Status

Accepted

## Context

`PowerSystems.jl` components store power per-unit and *display* it according to the `System`'s
active units base: `get_active_power_limits(gen)` returns MW under `NATURAL_UNITS` and per-unit
under `SYSTEM_BASE`, driven by `PSY.get_value(c, Val(field), Val(:mva))` and the component's
`units_info`.

`GenericConstraint.rhs`, the `"rhs"` time series, `FCASTrapezium`/`FCASBid`, and
`InterconnectorLossModel` stored raw MW as literal fields and ignored the units base entirely.
Under `NATURAL_UNITS` this was invisible - everything read as MW. Confirmed directly: building a
`System`, switching `set_units_base_system!(sys, "SYSTEM_BASE")`, a PSY device's
`get_active_power_limits` divided by its base power while `get_rhs(gc)` kept returning the raw
MW value unchanged - the `System` became internally inconsistent the moment anything other than
`NATURAL_UNITS` was used, which is exactly the units base `AustralianElectricityMarketsSimulations`
(AEMSim) builds its `PowerSimulations.jl` optimization model in.

The Phase 1 exit test (`test/integration/system_build_coverage.jl`,
`"unit contract: native MW/\$, not per-unitized"`) pinned the old, broken behaviour as a
contract. It only ever exercised a `System` left in `NATURAL_UNITS`, so it could not observe the
divergence.

## Decision

Every power quantity this package writes into a `System` is stored as per-unit of the system
base. Four data classes, each converted differently:

- `GenericConstraint`/`FCASService` scalar fields: `Service <: Component`, so `add_service!`
  stamps `units_info`. Accessors wrap `PSY.get_value`/`PSY.set_value` with `Val(:mva)`, exactly
  as a native PSY device field would. Neither type has its own `base_power` field, so
  `PSY.get_base_power` falls back to the system base - storing system-base pu makes the existing
  PSY machinery behave correctly with no bespoke conversion code.
- The `"rhs"`/`"lhs"` time series on `GenericConstraint`: PSY does not unit-convert time-series
  values on read. `add_nem_constraints!` divides by `get_base_power(sys)` once, before either
  series is written; a reader wanting MW must convert explicitly (`with_units_base` or
  multiplying by `get_base_power(sys)`), the same way it would for any other raw time series.
  `"marginal_value"` is a \$/MW price, not a power quantity, and is left unconverted, matching
  `$/MWh` bid prices.
- `FCASTrapezium`/`FCASBid`: `DeviceParameter` is not a `Component` and these live inside time
  series, so PSY's `units_info` machinery cannot apply. `set_fcas_bids!` divides every MW/
  MW-per-minute field (trapezium breakpoints, `max_avail`, ramp rates, offer-curve `x_coords`) by
  `get_base_power(sys)` before writing; `get_fcas_trapezium`/`get_fcas_offer_curve` in
  `src/fcas/access.jl` read the owning component's `units_info` (shared with the `System`'s own,
  even though `FCASTrapezium` has none of its own) to convert back to MW under `NATURAL_UNITS`.
  Offer-curve prices (`y_coords`) are never touched.
- `InterconnectorLossModel`: a `SupplementalAttribute`, which PSY never stamps with `units_info`
  at all, so there is no live conversion possible on read. `attach_interconnector_losses!`
  converts once, at attach time, via a private `_to_pu`: `breakpoints` divide by `base_power`;
  `loss_flow_coefficient` and `demand_coefficients` (both 1/MW) multiply by `base_power`;
  `loss_constant` and `from_region_loss_share` are dimensionless and unchanged. A model this
  package attaches to a `System` is therefore always per-unit; a model returned directly by
  `interconnector_loss_models` (not yet attached) is always natural-units MW.
  `loss_factor`/`interconnector_losses`/`loss_segments` are unit-agnostic - they were not
  changed - and require `flow`/`demand` to be passed in whatever convention `model` itself uses.

Not scaled, ever: `ConstraintTerm.factor` (dimensionless multiplier on an already-per-unit
variable), the `"invoked"` 0.0/1.0 mask, `constraint_weight`/`GENERICCONSTRAINTWEIGHT`
(dimensionless), `$/MWh`/`$/MW` prices, and `from_region_loss_share` (a fraction).

The Phase 1 exit test's `"unit contract"` testset is rewritten, not deleted, to assert the
opposite: values are per-unit under `SYSTEM_BASE` and equal the original MW under
`with_units_base(sys, "NATURAL_UNITS")`.

## Consequences

- AEMSim must never itself divide or multiply a value read off a `GenericConstraint`,
  `FCASService`, `FCASTrapezium`/`FCASBid`, or an attached `InterconnectorLossModel` by a base
  power. Every one of those is already in whatever unit `PowerSimulations.jl` expects for a
  `System`'s optimization variables (system-base per-unit) once this package has built the
  `System`; converting again would silently reintroduce the exact defect this ADR fixes, in the
  opposite direction.
- `"marginal_value"` stays in \$/MW while `"rhs"`/`"lhs"` become per-unit, so the two are no
  longer on a common basis. AEMO's published marginal value is a price per MW of the constraint's
  natural units; a dual recovered from a per-unitised constraint row is a price per per-unit, and
  is larger by the system base power. Anything comparing a solved dual against
  `"marginal_value"` - a replication harness scoring a solve against AEMO's own numbers, most
  obviously - must scale one side by `get_base_power(sys)` before the comparison means anything.

- A caller that only ever reads MW/\$ off these types (never switches a `System`'s units base
  away from `NATURAL_UNITS`) sees no behavioural change.
- `nem_system`'s base builder and `augmented_pscb_system()` (the test fixture) disagree on which
  units base a freshly-built `System` is left in. `nem_system` calls `PSY.System(BASE_POWER; ...)`
  with no `unit_system` kwarg, and `PSY.System`'s own default there is `"SYSTEM_BASE"` - so a
  production `System` starts in `SYSTEM_BASE`, per-unit, unless a caller explicitly switches it.
  `augmented_pscb_system()` instead calls `set_units_base_system!(sys, "NATURAL_UNITS")`
  immediately after building, so every integration test in this repo that uses it exercises the
  `NATURAL_UNITS` path almost exclusively - which is exactly why the old, broken contract could
  ship and pass for as long as it did. This discrepancy predates this PR and is not resolved
  here; a caller of `nem_system` should not assume a particular units base without checking
  `get_units_base(sys)`.
