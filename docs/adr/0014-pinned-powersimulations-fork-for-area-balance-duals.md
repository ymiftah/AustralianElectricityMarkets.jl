# 0014. A pinned `PowerSimulations.jl` fork supplies the area-balance dual

## Status

Accepted

## Context

`RegionalNetworkConfiguration` models the NEM as one `PSY.Area` per region and prices each region
from the dual of that area's `CopperPlateBalanceConstraint`. Under
`PowerSimulations.AreaBalancePowerModel` that constraint is keyed by `PSY.Area`.

`AreaBalancePowerModel <: PM.AbstractActivePowerModel`, so in stock `PowerSimulations.jl` 0.38.4
both `add_constraint_dual!` and `assign_dual_variable!` fall through to their generic
`NetworkModel{<:PM.AbstractPowerModel}` methods, which register a **bus-keyed** dual container.
That is the wrong shape: the constraint has no bus axis, so the regional price cannot be read
back.

## Decision

The correction lives in a fork of `PowerSimulations.jl`, pinned by exact revision in the
`[sources]` table of `AustralianElectricityMarketsSimulations/Project.toml`, not in an override
in `psi_compat.jl`. The fork adds `NetworkModel{AreaBalancePowerModel}` methods for both
functions (`src/devices_models/devices/common/add_constraint_dual.jl`, lines 45 and 185 at the
pinned revision) which register the `PSY.Area`-keyed container instead.

`psi_compat.jl` therefore defines no area-balance method. That file holds only the overrides this
package itself declares; a dependency pin is not an override and is not recorded there.

## Consequences

- `AustralianElectricityMarketsSimulations/test/psi_compat.jl` asserts that dispatch *selects*
  the `AreaBalancePowerModel`-specific method, via `which`. `hasmethod` cannot express this:
  stock 0.38.4 already has a generic method that matches the same call and returns the wrong
  container, so `hasmethod` is true either way.
- Those two assertions are the canary for the pin itself. An environment that resolves
  `PowerSimulations` without honouring `[sources]` — a shared workspace `Manifest.toml` resolved
  from the General registry, for instance — silently gets stock 0.38.4, and these are the only
  tests that fail. A local failure here means the environment is not running the fork; it is not
  a Julia version or platform artifact, and should not be dismissed as one.
- The pin is an exact revision, so a `PowerSimulations.jl` upgrade requires the fork to be
  rebased before the compat surface in `psi_compat.jl` can be re-checked.
- If the change is accepted upstream the `[sources]` entry can be dropped and this ADR
  superseded.
