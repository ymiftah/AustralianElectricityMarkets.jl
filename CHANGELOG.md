# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`IntervalInputs`/`read_interval_inputs`** (new `AustralianElectricityMarketsSimulations` package): Reads every NEMWEB input needed to reconstruct one historical dispatch interval in isolation — `DISPATCHLOAD.INITIALMW`/`UIGF`, `DISPATCHREGIONSUM.TOTALDEMAND`, rebid-resolved energy and FCAS bids, and `DISPATCHINTERCONNECTORRES.MWFLOW` — the foundation for the dispatch-replication harness that validates how closely `PowerSimulations.jl` reproduces NEMDE.
- **`DISPATCH_FCAS_REQ` data source**: Added ingestion support for AEMO's `DISPATCH_FCAS_REQ` table, and widened `DISPATCHLOAD`/`DISPATCHPRICE`/`DISPATCHREGIONSUM` to carry `RUNNO`/`INTERVENTION` and the remaining FCAS-related columns AEMO publishes on them.
- **`read_fcas_prices`/`read_fcas_dispatch`**: New readers for per-region FCAS clearing prices (`DISPATCHPRICE`) and per-unit FCAS dispatch outcomes (`DISPATCHLOAD`), complementing `read_fcas_requirements`.
- **`read_prices`**: New reader for per-region energy spot prices (`DISPATCHPRICE.RRP`/`ROP`/`APCFLAG`).
- **"FCAS in the NEM" documentation**: A new Explanation page walking through NEM FCAS markets, the offer trapezium, and dispatch co-optimisation from AEMO's own documents, with every figure computed from real NEMWEB data.
- **"The National Electricity Market" documentation**: A new Explanation page (the first in that section) introducing the NEM's institutions, market design, and dispatch process, and contrasting it with US ISO/RTO and European market designs, with a real-data figure of regional price divergence.
- **`GenericConstraint`/`ConstraintTerm`/`FCASRequirement`**: New NEM generic-constraint types (`src/constraints/`), representing both network limits and FCAS requirements as one `PowerSystems.Service` — matching how AEMO actually models them, rather than as separate `PowerSystems.Reserve` subtypes.
- **`read_invoked_constraints`/`read_constraint_definitions`/`read_constraint_terms`/`read_constraint_fcas_requirements`/`add_nem_constraints!`**: New readers and `System` builder for the constraint suite, joining `DISPATCHCONSTRAINT`'s per-interval `GENCONID_EFFECTIVEDATE`/`GENCONID_VERSIONNO` to `GENCONDATA`/`SPDCONNECTIONPOINTCONSTRAINT`/`SPDREGIONCONSTRAINT`/`SPDINTERCONNECTORCONSTRAINT` by exact version equality.
- **`ConstrainedNetworkConfiguration`**: Replaces `FCASNetworkConfiguration` — builds both FCAS bids and NEM generic constraints (network and FCAS-requirement alike) into the resulting `System`.
- **`DISPATCH_FCAS_REQ_CONSTRAINT`/`DISPATCH_FCAS_REQ_RUN` data sources**: AEMO last published `DISPATCH_FCAS_REQ` for the 2025-05 archive month and replaced it with these two (`GENCONID` → `CONSTRAINTID`, `SETTLEMENTDATE` → `INTERVAL_DATETIME`, no `INTERVENTION`, no `GENCONEFFECTIVEDATE`/`GENCONVERSIONNO`, plus new `LHS`/`RHS`/`RRP`/enablement/FPP-cost columns). Both are now ingested, and the new table is backfilled by AEMO rather than starting at the changeover, so the two overlap.
- **`read_uigf`**: a new reader for `DISPATCHLOAD.UIGF`, the per-unit Unconstrained Intermittent Generation Forecast: the weather ceiling AEMO's NEMDE actually applied to each semi-scheduled unit for each dispatch interval. Returns `SETTLEMENTDATE`, `DUID`, `UIGF` (MW). `UIGF` is `NULL` for scheduled units, so only semi-scheduled DUIDs appear. Supports the same `resolution` aggregation convention as `read_demand` and the same `intervention` run selection as the other dispatch readers, plus a single-interval `read_uigf(db, settlement_date::DateTime)` method that bounds the scan to one `SETTLEMENTDATE` — the dispatch-replication harness reads UIGF one interval at a time and now shares this reader instead of carrying its own copy of the query.
- **`GenericConstraint` as a `PowerSimulations.jl` service, energy terms only** (`AustralianElectricityMarketsSimulations/src/services/nem_constraints.jl`): `TermConstraint <: AbstractNEMConstraintFormulation <: PSI.AbstractServiceFormulation` drives `GenericConstraint` (now `<: PSY.Service`) through PSI's `ServiceModel` machinery — `NEMConstraintLHS`/`NEMConstraintLimit`/`NEMConstraintRHSParameter`, per-term-type `add_to_expression!` (`InterconnectorTerm`, and `UnitTerm`/`RegionTerm` restricted to `bid_type == ENERGY`; FCAS terms are a later task), and sense-dispatching `add_constraints!` that honours the `"invoked"` series. `AbstractNEMConstraintFormulation` (`services/constraint_formulations.jl`) mirrors PSI's own `AbstractReservesFormulation`, one level below `PSI.AbstractServiceFormulation`.
  `add_nem_constraints!` now attaches each constraint via `add_service!` with its resolved contributing devices — a `RegionTerm`'s every `Generator`/`Storage` unit in that region (Ruling R8) — and a constraint touching an unsupported bid_type or a device type this template doesn't model is skipped whole with one summary `@warn`, never with a partial LHS.
  A `UnitTerm`/`RegionTerm` resolving to a `PSY.Storage` unit contributes its net injection (`ActivePowerOutVariable - ActivePowerInVariable`, the same sign convention PSI's own nodal balance uses) rather than being treated as an unmodeled device type: storage formulations have no `ActivePowerVariable`, so keying off that alone dropped every constraint touching a battery — and, through `RegionTerm`, every constraint on a region containing one.
  `AustralianElectricityMarketsSimulations/src/psi_compat.jl` gained two more quarantined overrides: a no-op `PSI._modify_device_model!` for this formulation, and a no-op `PSI.get_initial_conditions_service_model` — PSI calls both unconditionally for every registered `ServiceModel` and neither has a fallback method, the latter reachable only once a template's device formulation itself needs initial conditions. Its `PSI.add_constraint_dual!` workaround is now defined only when the installed PSI has no `AreaBalancePowerModel` method of its own; defining it unconditionally overwrites PSI's once upstream registers those duals, which is a precompilation error.
  A not-invoked interval now registers a vacuous, disconnected constraint rather than leaving that cell unassigned — PSI's dual read-back broadcasts over the whole per-instance container regardless of which cells were ever filled, so an unfilled one threw `UndefRefError` the first time any interval was skipped. The per-`OptimizationContainer` skip-reason cache is a `WeakKeyDict`, not an `IdDict`, so it no longer pins every container built over a `Simulation`'s lifetime in memory.
- **NEM FCAS market participation as a `PowerSimulations.jl` service** (`AustralianElectricityMarketsSimulations/src/services/fcas_market.jl`): `NEMFCASMarket <: PSI.AbstractServiceFormulation` drives `NEMFCASService` (one component per NEM FCAS market, contributing devices resolved from each unit's `"fcas_trapezium_<SERVICE>"` series) through PSI's `ServiceModel` machinery — an `FCASCapacityVariable` per (unit, market, timestep), coupled into the unit's own energy headroom (`ActivePowerRangeExpressionUB`/`LB`) via NEMDE's trapezium slopes, and costed from the unit's offer curve via an epigraph formulation.
  `NEMFCASService` carries its market identity as a real `service::BidType` field (matching `FCASBid.service`) rather than parsing it from a name string, backed by new `is_raise_market`/`is_regulation_market` predicates on `BidType`.
  A device not fully coupled into shared headroom (missing `ActivePowerVariable` or its range-expression container) is reported once via a summary `@warn`, never silently. Decremental (load-direction) bidding stays out of scope.
  Stays a direct `PSI.AbstractServiceFormulation` subtype rather than joining `AbstractNEMConstraintFormulation` — mirrors how installed PSI keeps `TransmissionInterface`'s formulation a sibling of `AbstractReservesFormulation`, not a member of it.
  `AustralianElectricityMarketsSimulations/src/psi_compat.jl`'s quarantined `PSI._modify_device_model!` no-op now covers both `TermConstraint` and `NEMFCASMarket` via one `Union`-dispatched method.
- **FCAS terms in generic constraints, and price attribution** (`AustralianElectricityMarketsSimulations/src/services/nem_constraints.jl`, `.../services/fcas_pricing.jl`): an FCAS-typed `UnitTerm`/`RegionTerm` now resolves to `NEMFCASMarket`'s `FCASCapacityVariable` instead of being skipped — a device must both carry the market's bid series and hold an actual slot in that market's built variable container, since PSI narrows a service's contributing devices to types the device template models. No explicit construction ordering between `TermConstraint` and `NEMFCASMarket` is needed: every service's variable-creation stage completes before any service's constraint-building stage begins.
  `compute_fcas_prices` sums `TermConstraint` duals (rescaled to \$/MW) of every `GenericConstraint` governing a `(region, service)` pair, returning the same column names as `read_fcas_prices` for direct comparison against AEMO-published prices.

### Changed

- **`AustralianElectricityMarketsSimulations`**: Re-added `PowerSimulations`/`JuMP`/`HiGHS`/`HydroPowerSimulations` dependencies, pinned to `PowerSimulations = "0.38"` (PSI's service-model API, not the 0.34 line the abandoned replication work targeted), laying the groundwork for a PSI service-model integration of NEM generic constraints.
- **BREAKING: `read_constraint_fcas_requirements`/`read_fcas_requirements`/`add_nem_constraints!` (and `AustralianElectricityMarketsSimulations`'s interconnector-flow read behind `read_interval_inputs`) now throw `ArgumentError` when their table isn't cached at all**, instead of silently returning an empty `DataFrame`/`Dict`/`(String[], Dict())`. An empty result was indistinguishable from a genuine "nothing governs this" answer — the exact defect class behind `read_fcas_requirements` silently dropping every FCAS requirement after AEMO's 2025-05 table changeover. Each error names the missing table (`DISPATCH_FCAS_REQ`/`DISPATCH_FCAS_REQ_CONSTRAINT`, `DISPATCHCONSTRAINT`, or `DISPATCHINTERCONNECTORRES`) and the `populate` call to fix it.
- **`add_nem_constraints!`/`read_uigf` still warn (not throw) for a genuinely empty answer from a cached table**: `add_nem_constraints!` warns and returns `(String[], Dict())` when `DISPATCHCONSTRAINT` is cached but has no rows in the requested range — a real result, not missing data. `read_uigf` warns and returns an empty frame when `DISPATCHLOAD` is cached but every partition predates the `UIGF` column — ordinary schema evolution `read_hive`'s `union_by_name` exists to tolerate, not a missing download. Both still throw when their table isn't cached at all.
- **`_table_is_cached`**: No longer catches every exception into `false`. A glob matching zero files is still a legitimate `false`, but a genuine failure to check (bad S3/GS credentials, a network drop, corrupt parquet) now raises DuckDB's own error instead of being silently reported as "not cached".
- **`read_fcas_requirements`**: Rewritten to read the generic-constraint-based `DISPATCH_FCAS_REQ`/`DISPATCHCONSTRAINT`/`GENCONDATA` tables instead of the `RESERVE` table, which AEMO stopped populating in Dec 2003. The `RESERVE` table entry has been removed from `_TABLE_SPECS` accordingly.
- **`read_hive`**: Now reads with `union_by_name=true`, so a table's `_TABLE_SPECS` entry can grow new columns without invalidating partitions already cached under an older, narrower schema.
- **Market price cap**: Corrected stale `$17,500/MWh` figures (FY2024-25) in the docs to the current `$23,200/MWh` (FY2026-27).
- **FCAS requirements are no longer modelled as `PowerSystems.Reserve`s**: `ContingencyFCASReserve`/`RegulationFCASReserve`/`FCASResponseTime`/`NEMMarketBidCost` are removed. A `PSY.Reserve` cannot represent a requirement governed by several constraints at once, netting an interconnector flow, or armed/disarmed by a large RHS offset — all of which are common in real NEMWEB data (see the "FCAS in the NEM" docs page). `FCASOffer` is renamed `FCASBid` (keyed by `BidType`, not a reserve name) and `set_fcas_offers!` is renamed `set_fcas_bids!`, now attaching a genuinely time-varying `Deterministic` series instead of a single-interval snapshot.
- **Documentation CI**: The `Documentation` workflow's `pull_request` trigger is now scoped to `main`, so PRs targeting other branches (e.g. release branches) no longer run the docs build.
- **`set_renewable_pv!`/`set_renewable_wind!`**: now use per-unit UIGF instead of regional availability. They previously read `DISPATCHREGIONSUM.SS_SOLAR_AVAILABILITY`/`SS_WIND_AVAILABILITY` — regional *aggregates* — and applied one normalised regional shape to every unit in the region, rescaled by that unit's own nameplate. Unit-level availability never entered. They now read each unit's own `UIGF` via the new `read_uigf`, which is the ceiling NEMDE itself applied. Units with no `UIGF` keep their static `max_active_power`.
- **`add_nem_constraints!` no longer hardcodes its series resolution to `Minute(5)`**: it now takes a `resolution` keyword (default `nothing`), and when unset infers the resolution from the spacing between consecutive points in the invoked-constraint grid rather than assuming it. A grid with fewer than 2 points falls back to `Minute(5)`, since a single interval carries no spacing information. If the grid's spacing turns out not to be uniform — a gap in the underlying `DISPATCHCONSTRAINT` data — it now warns naming the distinct spacings found and proceeds using the smallest one, instead of silently mislabelling the attached `Deterministic` series with a resolution that doesn't match its own timestamps. Passing `resolution` explicitly skips inference and validation, as before.

### Fixed

- **Stale data-fetching documentation**: The README, docs landing page, "Gathering Data" page, and the commented download snippets in the Literate examples all referenced a `fetch_table_data` function and a `PyHiveConfiguration` type that no longer exist. They now use `populate` and `HiveConfiguration`, and the description of the package as a wrapper around a Python package has been removed.
- **`read_bids`/`read_fcas_bids` discarded `MAXAVAIL`/`MINIMUMLOAD`/`DAILYENERGYCONSTRAINT`**: `_massage_bids` queried these physical-bound columns from `BIDPEROFFER_D`/`BIDDAYOFFER_D` but dropped them before returning, leaving only the priced curve. They are now retained on the output; `_read_fcas_trapezium` no longer selects its own duplicate `MAXAVAIL`, since `read_fcas_bids`'s join now gets it from the same place.
- **`set_fcas_bids!` silently dropped `LOAD`/`BIDIRECTIONAL`-direction FCAS bids**: it only ever iterated `Generator` components with `DIRECTION = 'GEN'`, so batteries and other bidirectional providers — a large share of real FCAS volume in several markets — got no FCAS data at all. It now also attaches to `EnergyReservoirStorage`: `GEN`/`BIDIRECTIONAL` rows under the existing series names, `LOAD` rows under a new `"<SERVICE>_decremental"` suffix, mirroring `set_market_bids!`'s incremental/decremental split.
- **`add_nem_constraints!` dropped constraints with partial interval coverage** instead of handling them: a `GENCONID` invoked for fewer intervals than its peers (its constraint set started or stopped applying partway through the range) was skipped entirely rather than added. On a week of real `DISPATCHCONSTRAINT` data this dropped 45% of invoked constraints, including over a quarter of the ones that ever bind. It is now added with its `"rhs"`/`"lhs"` series padded to the full interval grid (last known value carried forward) and a new `"invoked"` series (`1.0`/`0.0`) recording which intervals were real.
- **`read_constraint_fcas_requirements`/`read_fcas_requirements` returned nothing after 2025-05**: both read `DISPATCH_FCAS_REQ`, which AEMO stopped publishing after that archive month, so any later date range produced an empty result — and for `add_nem_constraints!` an empty `fcas_requirements` list is indistinguishable from "this is a pure network constraint", making every FCAS requirement silently vanish. Both now read through a union of `DISPATCH_FCAS_REQ` and its successor `DISPATCH_FCAS_REQ_CONSTRAINT`, deduplicated over the months where AEMO publishes both, so attribution is continuous across the changeover. Two caveats are documented rather than papered over: the successor has no `INTERVENTION` column, so `intervention` filters the old table only; and it drops the `GENCONEFFECTIVEDATE`/`GENCONVERSIONNO` pair, so post-changeover `GENCONDATA` enrichment falls back to the latest version effective at the interval instead of an exact-version match.
- **`populate` silently skipped months it was merely rate-limited on**: `_get_archive` mapped *every* `HTTP.Exceptions.HTTPError` — 403, 429, 5xx, connection resets — to `MissingDataError`, which `populate` logs as "No data available" and skips. NEMWEB rate-limits bulk fetches with 403, so a wide date range could report success while leaving holes indistinguishable from months AEMO never published (observed directly: 180 such skips in one bulk run, including months verified to exist). Downloads now classify the response — 404 alone means absence; 403/408/425/429/5xx and connection failures retry up to 5 times with exponential backoff and then raise the new `TransientDownloadError`, which `populate` deliberately does **not** swallow. The primary→alternative URL fallback now fires only on a genuine 404, so a throttled run stops adding load instead of doubling it.
- **Renewable ceilings were normalised by the in-window maximum**, so the reconstructed MW depended on how wide a `date_range` the caller asked for, and the last interval of any window was always pinned to the unit's full registered capacity. Seeding a single dispatch interval (a 2-point window, as the dispatch-replication harness does) therefore gave every semi-scheduled unit a ceiling at ~100% of nameplate. An all-zero window — solar overnight — divided by zero and wrote `NaN` into the time series with no error. Both are gone: `UIGF` is an absolute MW figure per unit per interval, so no window-relative normalisation happens at all.
- **Time-series setters depended on the `System`'s units base at write time**: `_add_demand_ts_to_components!` divides by `get_max_active_power`, which is itself unit-mode-aware, so the stored series came out a factor of `get_base_power(sys)` wrong when the setter was called in one units base and read back expecting the other. `nem_system` leaves a `System` in `SYSTEM_BASE` (what the Literate docs pages use) while the replication harness switches to `NATURAL_UNITS` first, so the two call sites disagreed. The divisor is now always taken in `NATURAL_UNITS` via `with_units_base`, making the stored series identical regardless of the caller's units base.
- **`read_bids`/`set_market_bids!`/`set_hydro_limits!` mis-aggregated bids at any resolution other than 5 minutes**: `_massage_bids` summed `MAXAVAIL` across the intervals in each bucket while pre-scaling `BANDAVAIL` by `Minute(5) / resolution` and summing that — two different conventions for two quantities that are both MW. At 30-minute resolution a bucket covering six intervals returned `MAXAVAIL = 621.0` where the true mean was `103.5` (6x inflated; 12x hourly), so `set_hydro_limits!`, which uses `MAXAVAIL` as the hydro ceiling, gave every hydro unit roughly twelve times its nameplate on an hourly read. Separately, `ceil` leaves the first bucket a singleton, and the scale-then-sum trick is only valid for a *full* bucket, so `BANDAVAIL` there came back at `1/12` of its true value. The two errors cancel at the 5-minute default, which is why neither surfaced. Both quantities are now aggregated with `mean`, which is correct for full and partial buckets alike.

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
