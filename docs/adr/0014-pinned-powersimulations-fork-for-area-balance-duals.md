# 0014 A pinned `PowerSimulations.jl` fork supplies the area-balance dual

## Status

Accepted

## What

- The regional price is the dual of the `PSY.Area`-keyed `CopperPlateBalanceConstraint` under `PSI.AreaBalancePowerModel`. Stock PSI 0.38 registers a bus-keyed dual container for that model, so the price cannot be read back.
- A fork adds `NetworkModel{AreaBalancePowerModel}` methods of `add_constraint_dual!` and `assign_dual_variable!` that register the `PSY.Area`-keyed container. It is pinned by exact revision in `[sources]` of `AustralianElectricityMarketsSimulations/Project.toml`.

## How

- `psi_compat.jl` holds only overrides this package declares, so it has no area-balance method.
- `test/psi_compat.jl` asserts via `which` that dispatch selects the `AreaBalancePowerModel` method. `hasmethod` cannot, because stock PSI has a generic method matching the same call.

## Why

- Those assertions are the canary for the pin: an environment that ignores `[sources]` silently gets stock PSI and only these tests fail. Treat a failure as "not running the fork".
- A PSI upgrade needs the fork rebased and `psi_compat.jl` re-checked. If upstream accepts the change, drop the pin.
