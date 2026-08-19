# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`DISPATCH_FCAS_REQ` data source**: Added ingestion support for AEMO's `DISPATCH_FCAS_REQ` table, and widened `DISPATCHLOAD`/`DISPATCHPRICE`/`DISPATCHREGIONSUM` to carry `RUNNO`/`INTERVENTION` and the remaining FCAS-related columns AEMO publishes on them.
- **`read_fcas_prices`/`read_fcas_dispatch`**: New readers for per-region FCAS clearing prices (`DISPATCHPRICE`) and per-unit FCAS dispatch outcomes (`DISPATCHLOAD`), complementing `read_fcas_requirements`.
- **`read_prices`**: New reader for per-region energy spot prices (`DISPATCHPRICE.RRP`/`ROP`/`APCFLAG`).
- **"FCAS in the NEM" documentation**: A new Explanation page walking through NEM FCAS markets, the offer trapezium, and dispatch co-optimisation from AEMO's own documents, with every figure computed from real NEMWEB data.
- **"The National Electricity Market" documentation**: A new Explanation page (the first in that section) introducing the NEM's institutions, market design, and dispatch process, and contrasting it with US ISO/RTO and European market designs, with a real-data figure of regional price divergence.
- **`GenericConstraint`/`ConstraintTerm`/`FCASRequirement`**: New NEM generic-constraint types (`src/constraints/`), representing both network limits and FCAS requirements as one `PowerSystems.Component` — matching how AEMO actually models them, rather than as separate `PowerSystems.Reserve` subtypes.
- **`read_invoked_constraints`/`read_constraint_definitions`/`read_constraint_terms`/`read_constraint_governs`/`add_nem_constraints!`**: New readers and `System` builder for the constraint suite, joining `DISPATCHCONSTRAINT`'s per-interval `GENCONID_EFFECTIVEDATE`/`GENCONID_VERSIONNO` to `GENCONDATA`/`SPDCONNECTIONPOINTCONSTRAINT`/`SPDREGIONCONSTRAINT`/`SPDINTERCONNECTORCONSTRAINT` by exact version equality.
- **`ConstrainedNetworkConfiguration`**: Replaces `FCASNetworkConfiguration` — builds both FCAS bids and NEM generic constraints (network and FCAS-requirement alike) into the resulting `System`.

### Changed

- **`read_fcas_requirements`**: Rewritten to read the generic-constraint-based `DISPATCH_FCAS_REQ`/`DISPATCHCONSTRAINT`/`GENCONDATA` tables instead of the `RESERVE` table, which AEMO stopped populating in Dec 2003. The `RESERVE` table entry has been removed from `_TABLE_SPECS` accordingly.
- **`read_hive`**: Now reads with `union_by_name=true`, so a table's `_TABLE_SPECS` entry can grow new columns without invalidating partitions already cached under an older, narrower schema.
- **Market price cap**: Corrected stale `$17,500/MWh` figures (FY2024-25) in the docs to the current `$23,200/MWh` (FY2026-27).
- **FCAS requirements are no longer modelled as `PowerSystems.Reserve`s**: `ContingencyFCASReserve`/`RegulationFCASReserve`/`FCASResponseTime`/`NEMMarketBidCost` are removed. A `PSY.Reserve` cannot represent a requirement governed by several constraints at once, netting an interconnector flow, or armed/disarmed by a large RHS offset — all of which are common in real NEMWEB data (see the "FCAS in the NEM" docs page). `FCASOffer` is renamed `FCASBid` (keyed by `BidType`, not a reserve name) and `set_fcas_offers!` is renamed `set_fcas_bids!`, now attaching a genuinely time-varying `Deterministic` series instead of a single-interval snapshot.
- **Documentation CI**: The `Documentation` workflow's `pull_request` trigger is now scoped to `main`, so PRs targeting other branches (e.g. release branches) no longer run the docs build.

### Fixed

- **Stale data-fetching documentation**: The README, docs landing page, "Gathering Data" page, and the commented download snippets in the Literate examples all referenced a `fetch_table_data` function and a `PyHiveConfiguration` type that no longer exist. They now use `populate` and `HiveConfiguration`, and the description of the package as a wrapper around a Python package has been removed.
- **`read_bids`/`read_fcas_bids` discarded `MAXAVAIL`/`MINIMUMLOAD`/`DAILYENERGYCONSTRAINT`**: `_massage_bids` queried these physical-bound columns from `BIDPEROFFER_D`/`BIDDAYOFFER_D` but dropped them before returning, leaving only the priced curve. They are now retained on the output; `_read_fcas_trapezium` no longer selects its own duplicate `MAXAVAIL`, since `read_fcas_bids`'s join now gets it from the same place.
- **`set_fcas_bids!` silently dropped `LOAD`/`BIDIRECTIONAL`-direction FCAS bids**: it only ever iterated `Generator` components with `DIRECTION = 'GEN'`, so batteries and other bidirectional providers — a large share of real FCAS volume in several markets — got no FCAS data at all. It now also attaches to `EnergyReservoirStorage`: `GEN`/`BIDIRECTIONAL` rows under the existing series names, `LOAD` rows under a new `"<SERVICE>_decremental"` suffix, mirroring `set_market_bids!`'s incremental/decremental split.
- **`add_nem_constraints!` dropped constraints with partial interval coverage** instead of handling them: a `GENCONID` invoked for fewer intervals than its peers (its constraint set started or stopped applying partway through the range) was skipped entirely rather than added. On a week of real `DISPATCHCONSTRAINT` data this dropped 45% of invoked constraints, including over a quarter of the ones that ever bind. It is now added with its `"rhs"`/`"lhs"` series padded to the full interval grid (last known value carried forward) and a new `"invoked"` series (`1.0`/`0.0`) recording which intervals were real.

## [0.1.3] - 2026-03-09

### Added

- **Literate.jl Documentation**: Switched all documentation examples from hand-written Markdown to [Literate.jl](https://fredrikekre.github.io/Literate.jl/v2/), enabling executable, tested documentation notebooks (#61).

### Changed

- **nemdb v0.4.0**: Bumped the `nemdb` Python dependency to v0.4.0, updating API call signatures in `AustralianElectricityMarketsData.jl` and `configurations.jl` accordingly (#60).
- **Build System**: Streamlined the documentation CI workflow and added Git LFS tracking for test Parquet fixtures (#59).
- **CI Rollback**: Restored stable CI/CD configuration for Documentation and TagBot workflows (#56).

### Fixed

- Removed stale fetch test helper calls in `test/fetch_data.jl` (#57).

## [0.1.2] - 2026-01-31

### Added

- **Storage Model Support**: Introduced full support for battery storage components (`EnergyReservoirStorage`).
- **Bi-directional Bidding**: Added automated handling of both generation ("GEN") and load ("LOAD") market bids for storage units.
- **New Documentation**: Added a comprehensive "Clearing with Batteries" example (`docs/src/examples/clearing-with-batteries.md`).
- **Decremental Cost Curves**: Added support for concave decremental variable cost curves derived from load bids.

### Changed

- **Parser Refactoring**: Significant overhaul of `set_market_bids!` in `src/parser.jl` to handle storage components separately from standard generators.
- **Bid Extraction Logic**: Improved `PiecewiseStepData` extraction to correctly handle the directionality of bids.
- **Documentation Updates**: Updated multiple existing examples (`economic_dispatch.md`, `market_bids.md`, `interchanges.md`) to reflect the new storage model capabilities.

### Fixed

- **Storage Capacity Scaling**: Fixed an issue where storage capacity was not correctly scaled by `base_power` during component addition in `region_model.jl`.

## [0.1.1] - 2026-01-27

### Added

- New project roadmap documentation (`docs/src/roadmap.md`).

### Changed

- **CI/CD Overhaul**: Streamlined GitHub Actions workflows, merging test and CI scripts into a unified `Test.yml`.
- **Quality Control**: Add hooks to `pre-commit` for automated linting and formatting.
- **Documentation**: Cleanup of examples, fixing typos, and improving cross-linking.
- **Project Structure**: Removed deprecated `geoutils.jl` and simplified `Project.toml` dependencies.

### Fixed

- Link duplication and typos in documentation examples (#44).

## [0.1.0] - 2026-01-26

### Added

- **Mock Testing Framework**: Introduced `test/mock_data.jl` for generating Hive-partitioned Parquet datasets, enabling offline and fast testing.
- **Comprehensive Testing**: Added extensive unit tests for `RegionModel`, `DataReader`, and time-series setters.
- **New Examples**: Added "Gathering Data" example documentation.
- **Cloud Support**: Enhanced database reader and parsers for better compatibility with cloud storage (S3/GCS) and Hive-partitioned layouts.

### Changed

- **Licensing**: Formalized the project under the BSD 3-Clause license.
- **Interconnector Logic**: Refactored `region_model.jl` to correctly handle interconnector constraints and directionality.

### Fixed

- Bug in interface definitions and interchange examples (#42).
- Date range ceiling and boundary issues in data parsers (#38).
- Various minor fixes in `parser.jl` for 5-minute vs 30-minute resolution handling.

---

[Unreleased]: https://github.com/ymiftah/AustralianElectricityMarkets.jl/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/ymiftah/AustralianElectricityMarkets.jl/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/ymiftah/AustralianElectricityMarkets.jl/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/ymiftah/AustralianElectricityMarkets.jl/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/ymiftah/AustralianElectricityMarkets.jl/releases/tag/v0.1.0
