# 0088. The ISP portfolio package resolves in its own environment

## Status

Accepted.

## Context

`AustralianElectricityMarketsPortfolio` depends on `PowerSystemsInvestmentsPortfolios`, pinned to
revision `c1150d6eadaa3d28f36575e7232d8d77dc722cca`. That revision requires HTTP `1.10` to `1`, while
the workspace's root `Manifest.toml` resolves HTTP 2.7.1. Resolving the package as a fifth workspace
member fails with an unsatisfiable HTTP requirement, and the only shared-manifest solution would be
to downgrade HTTP to 1.11.1 for every package in the workspace.

The compatibility gate in `test/isp_portfolio/compatibility/` had already resolved PSIP against
PowerSystems 5.12.4, InfrastructureSystems 3.6.3 and the PowerSimulations fork, in an isolated
project: HTTP 1.11.1 there. So the dependency set is workable, but not inside one manifest with the
NEMWEB and NEMDE packages.

## Decision

`AustralianElectricityMarketsPortfolio` is a standalone Julia project with its own `Manifest.toml`,
not an entry in the root `[workspace]`. Its `[sources]` pin PowerSystems and InfrastructureSystems
to the same revisions the workspace uses, so those two resolve to the same versions (PowerSystems
5.12.4, InfrastructureSystems 3.6.3) even though the manifests are separate. PSIP is pinned to the
revision already validated by `test/isp_portfolio/compatibility/`; it appears in no other project.

Its CI workflow runs `julia-buildpkg` and `julia-runtest` against the package project, which resolves
its own manifest on the runner.

## Consequences

- AEM's operational environment keeps HTTP 2.7.1. PSIP never enters the environment of Cache, Data,
  AEM core or Simulations, and those suites are unaffected by its dependency tree.
- The package is instantiated separately (`julia --project=AustralianElectricityMarketsPortfolio`).
  Its manifest is gitignored like the root one, so CI resolves it from `[sources]` each run.
- Version drift between the two manifests is possible. Bumping the PowerSystems or
  InfrastructureSystems revision in the root `Project.toml` alone leaves the package on its old
  revision, and the package's CI still passes, because it resolves its own pin. A change to either
  shared revision must be applied to both `Project.toml` files in the same PR.
- Moving the package into the workspace later requires PSIP to drop its HTTP 1.x bound, or the
  workspace to accept HTTP 1.x.
