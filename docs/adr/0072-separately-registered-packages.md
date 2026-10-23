# 0072. Register each package separately

## Status

Accepted.

## Context

The repository holds four packages in a Julia 1.11 workspace: the root `AustralianElectricityMarkets`
package, `AustralianElectricityMarketsCache`, `AustralianElectricityMarketsData` and
`AustralianElectricityMarketsSimulations`. The siblings are linked by `[sources]` paths. Users should
be able to add `AustralianElectricityMarketsData`, `AustralianElectricityMarkets` or
`AustralianElectricityMarketsSimulations` alone. Makie.jl does this: one repository, one folder per
package, each package registered in General with `subdir` and released together.

## Decision

- Each package is registered from its own folder: `@JuliaRegistrator register subdir=<Folder>`. The
  root package is registered without `subdir`. `AustralianElectricityMarketsCache` is registered too,
  since `AustralianElectricityMarkets` and `AustralianElectricityMarketsData` depend on it.
- `[sources]` stays for development. Pkg honours it only in the active project or workspace, so
  registry users resolve the siblings from General.
- Compat between siblings uses the normal caret ranges, with the lower bound raised to the version
  released alongside. A package's compat on a sibling is bumped in the same PR that bumps the
  sibling's version.
- TagBot runs once per package. The root keeps `vX.Y.Z` tags and subfolder packages get
  `<PackageName>-vX.Y.Z` tags. CompatHelper and Dependabot cover each package folder and ignore the
  siblings.
- A manual `TestRegistered` workflow strips `[sources]`, the workspace and the manifests, then tests
  each package against its registered siblings, which is what a user installs.
- One `CHANGELOG.md` covers the repository. A release heading names each package version it releases.
- Release order: Cache, then AEMData and AEM, then AEMSim. One PR bumps the version of every changed
  package and the compat of its siblings. After that PR merges, one Registrator comment is posted per
  package in this order, each waiting for the previous package to merge in General.

## Consequences

- AEMSim cannot be registered while it depends on the pinned PowerSimulations fork through `[sources]`
  (see [`0014`](0014-pinned-powersimulations-fork-for-area-balance-duals.md)). A registry install would
  resolve upstream PowerSimulations. The fork changes must be released upstream first, and
  `TestRegistered` fails for AEMSim until then.
- Until Cache, AEMData and AEMSim are registered, `TestRegistered` fails for any package that depends
  on an unregistered sibling. The root test environment uses AEMData.
- Registration needs the JuliaRegistrator GitHub App installed on the repository.
