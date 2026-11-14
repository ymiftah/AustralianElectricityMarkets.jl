# ISP ingestion and investment portfolio design

Date: 4 November 2026. Branch: `isp2026-plexos-parsing` (PR #112, base `v0.2`).

## Intent

AEM should be able to build an investment-planning case from AEMO's 2026 Integrated System
Plan (ISP) PLEXOS model, the way it already builds NEM dispatch replays from NEMWEB. The first
use is a multi-year economic dispatch with transmission network expansion planning (TNEP) on
the Step Change scenario. This design covers getting the data in and turning it into Julia
objects. Writing and solving the optimisation is later work.

The work splits at the database:

1. **AEMData** downloads the ISP archives and copies the PLEXOS XML and CSV traces, unchanged,
   into DuckDB tables in the cache.
2. **A new workspace package, `AustralianElectricityMarketsPortfolio`**, depends on
   PowerSystemsInvestmentsPortfolios (PSIP). It reads those tables and builds PowerSystems
   (PSY) and PSIP objects inside an `AEMInvestmentPortfolio` wrapper.

## Goals

- One call populates the ISP cache from AEMO's archives, verified by hash and row counts.
- The cached tables are a faithful copy of the PLEXOS source: the 27 raw `t_*` tables per
  scenario, with original columns and values.
- The Portfolio package builds a Step Change `AEMInvestmentPortfolio` containing everything a
  multi-year economic dispatch / TNEP needs (see Milestone 1).
- The built portfolio's existing capacity per region and demand totals are checked against
  AEMO's own published figures.

## Non-goals

- Investment or dispatch optimisation formulations, and running PSINV
  (PowerSystemsInvestments). PSINV is not a dependency of either package.
- Matching AEMO's ISP optimal development path.
- Interpreting data on the Data side: no property resolution, unit conversion or pivoting.
- Scenarios other than Step Change in Milestone 1. The cache still holds all three, and
  nothing in the Portfolio package should assume Step Change.
- ISP releases other than 2026.

## Anti-goals

These would make the work a failure even if it ran:

- An unresolved or missing input silently becoming zero or a default. Unresolved inputs must
  stay visible, with the source record that caused them.
- Fallbacks for missing or malformed cached data. A bad cache is fixed by repopulating with
  `force_new = true`, not worked around.
- Getting around AEMO's download protection. Scripted requests to the archive URLs currently
  return HTTP 403. The code may try a plain request but must not spoof browsers, replay
  cookies or otherwise evade the block.
- Changing AEM's existing operational dependency pins (PSY 5.12.4, InfrastructureSystems
  3.6.3, the PowerSimulations fork), or adding PSIP to AEM core, Cache, Data or Simulations.
- Writing to or modifying source archives, or modifying the cache from the Portfolio package.

## Part 1: AEMData ingestion

### Release list

A built-in, versioned description of the 2026 ISP release (dated 28 September 2026 on AEMO's
page) lists the five archives: model, hydro traces, solar traces, wind traces and timeslice
traces. Each entry carries its AEMO URL, revision ID and SHA-256. The values are in
`~/.nemdb_cache/ISP/2026/isp.sources.json` and
`/run/media/simba/Store/aem_validation/isp2026/2026-09-28/downloads.json`. Source page:
<https://www.aemo.com.au/energy-systems/major-publications/integrated-system-plan-isp/2026-integrated-system-plan-isp>.

### Download behaviour (decided)

- The populate call takes a local archive folder.
- Archives already in that folder are used.
- For each missing archive it tries a plain HTTP download from AEMO.
- If AEMO refuses, it throws an error that lists, for every missing archive, the browser link
  and the exact file name and folder to save it into. Rerunning then picks up the saved files.
- Every archive's SHA-256 is checked before use. A mismatch is an error: it means AEMO
  published a new revision and the release list needs updating.
- Browser downloads get names like `2026 ISP Model (1).zip`. The builder decides whether the
  error asks for a canonical file name or the loader matches archives by hash.

### Loading (decided)

- One DuckDB schema per scenario (`accelerated_transition`, `slower_growth`, `step_change`),
  each holding all 27 `t_*` tables with the original field names. Values stay `VARCHAR`, and
  absent XML fields are SQL `NULL`. Each scenario has its own schema because PLEXOS
  `object_id`s are only unique within one XML file.
- Each CSV trace is loaded once into a `traces` schema, as a table named after the SHA-256 of
  its bytes, with original columns as `VARCHAR`. Files with identical bytes share a table.
- A `cache_meta` schema records the XML tables, trace files, Data File references resolved to
  trace tables, provenance (URLs, revisions, hashes, retrieval method, import time) and source
  versus imported row counts.
- Each scenario schema gets a `trace_bindings` view joining Data File properties to their
  trace tables.
- The layout matches the existing `~/.nemdb_cache/ISP/2026/isp.duckdb` built by
  `docs/analysis/extract_isp_cache.py`, documented in `docs/analysis/isp2026-cache.md`. The
  Julia loader should produce an equivalent database, and the cache notes should stay valid.
- The database is a separate file at `~/.nemdb_cache/ISP/2026/isp.duckdb`, under the
  configured cache root.

### Behaviour

- Idempotent like `populate`: a cached release is skipped unless `force_new = true`.
- Loading validates as it goes: every XML record count and every CSV row count matches the
  imported table, and every Data File reference resolves to a trace table. Any failure is an
  error, and a partly built database is not left in place as if it were complete.
- The existing PR #112 code in `AustralianElectricityMarketsData/src/isp2026/` is the
  starting point. Its XML reader currently keeps 13 of the 27 tables and loads into an
  `AEMDB` schema. It must keep all 27 and write the layout above.
- `resolve_properties` and its helpers in `isp2026/properties.jl` interpret data (date, band,
  tag and timeslice precedence). They move to the Portfolio package.
- `extract_isp_cache.py` stays in `docs/analysis/` as the record of the first extraction.

### IASR workbook (decided)

The PLEXOS package has no transmission candidates. Its 18 Lines carry only flow limits,
losses and capacity reserves, with 135 dated Max Flow values that fix the published
transmission plan, and only Generators and Batteries have Build Cost. The 2026 ISP Inputs
and Assumptions workbook (final, dated 25 June 2026 on AEMO's 2026 ISP page, `.xlsm`) holds
what is missing, so it is in scope:

- flow path augmentation options for the 14 flow paths, and their cost forecasts per scenario;
- REZ augmentation options and REZ cost forecasts;
- energy efficiency (residential and business), EV uptake and EV energy, and demand-side
  participation;
- financial parameters (discount rate, WACC), retirements and an existing-generation summary.

How it is handled:

- The workbook is a sixth entry in the release list, with the same download rules: try AEMO,
  and if refused, report the browser link and save location; then verify the hash.
- AEMData stores it raw: every sheet's cells in an `iasr` schema, keyed by sheet name, row and
  column, with the cell value as text. No tables are located or interpreted there.
- The Portfolio package locates and reads the tables it needs from those cells.
- The open-source `isp-workbook-parser` (GPL-3.0) documents the table locations for this
  workbook as version 7.8. Use it as a reference only. Its configuration files must not be
  copied into this MIT-licensed repository.

### Constraints

- AEMData keeps no dependency on AEM, Simulations, PSY or PSIP.
- Tests use small generated fixtures (an XML and a few CSVs zipped into fake archives) and
  never hit the network. The existing `isp2026_fixture.jl` is the starting point.
- A local real-data check, outside `Pkg.test` and CI, compares the Julia-built database with
  the Python-built one: same schemas, tables, columns and row counts, and identical values.
- The model archive is 117 MB compressed and 536 MB uncompressed, and the whole set produces
  a DuckDB file of about 860 MB. The 14 GB machine OOMs when two Julia jobs run at once, so
  memory use while loading matters. Extracted files and temporary data go on disk, not
  `/tmp`. The builder decides between extracting to disk and streaming from the ZIP.

## Part 2: `AustralianElectricityMarketsPortfolio`

### Package (decided)

- A new workspace package in `AustralianElectricityMarketsPortfolio/`, with its own
  `test/` project, added to the root `[workspace]`, with its own CI workflow following the
  existing per-package pattern.
- It depends on PSIP, PSY, InfrastructureSystems, DuckDB and Cache for configuration and
  connection. It does not depend on AEMData: it reads a populated cache, the same way AEM core
  reads NEMWEB parquet without the download code. My call: it does not depend on AEM core.
  The ISP system is not built from NEMWEB, so no AEM code is needed.
- PSIP is pinned through `[sources]` to revision
  `c1150d6eadaa3d28f36575e7232d8d77dc722cca` (branch `jp/capex`), the revision verified by
  the compatibility gate in `test/isp_portfolio/compatibility/`. PSY, IS and PowerSimulations
  must resolve to the same versions as AEM's root manifest.
- The architecture agreed on 28 October 2026 stands, as described in
  `docs/analysis/isp-modelling-stack-research.md` ("Agreed portfolio architecture") and the
  reuse table of `docs/superpowers/plans/2026-10-28-isp-investment-portfolio.md`:
  `AEMInvestmentPortfolio` wraps a genuine `PSIP.Portfolio`. Existing assets are PSY
  components, and standard investment data uses standard PSIP types. AEM-specific types are
  added only for ISP meaning that PSIP cannot hold, each justified by a specific gap.
- That plan put the PSIP code in an optional extension of AEM core. This design replaces the
  extension with the separate package. The plan's Tasks 2 to 4 are re-planned against this
  design.
- Serializable types must live in the package's top-level module.

### Source layer

- The package reads the scenario's tables into source records that keep PLEXOS identity:
  scenario, class, collection, membership, property, and the date, band, tag, timeslice and
  Variable/Data File scoping of each value. Originals stay available alongside any
  interpreted value.
- Property resolution moves here from AEMData. Its rules must follow PLEXOS semantics and
  AEMO's ISP model instructions; the earlier fixes in PR #112 (Timeslice Include flag,
  self-named month timeslices, Firm Capacity matching the horizon month) carry over.
- Trace data is read on demand (decided). The portfolio carries handles to trace tables, not
  loaded time series, and a trace is read from the cache only when asked for.
- The cache is opened read-only.

### Milestone 1: Step Change portfolio for multi-year economic dispatch and TNEP

The portfolio covers every year of the ISP horizon. It is not projected to a single
effective date: dated values keep their full history, and any projection is a derived view.

| Content | Source in the PLEXOS model (Step Change counts) | Target |
| --- | --- | --- |
| Network | 15 Nodes (subregions), 5 Regions, 19 Zones, 18 Lines | PSIP topology (planning regions); existing lines as PSY components |
| Interconnector options | IASR workbook: flow path augmentation options and cost forecasts (14 flow paths); REZ augmentation options and costs | PSIP transport technologies (candidates) |
| Existing fleet | Generators (1,194), Batteries (432), Storage (22) with existing capacity | PSY components linked through `ExistingDevices` |
| New entrants | Generator and battery candidates with costs and build limits | `PSIP.SupplyTechnology`, `PSIP.StorageTechnology` |
| Profiles | Wind, solar and hydro traces | Time series on the relevant technologies or components |
| Demand | Operational demand traces per subregion | PSIP demand requirements |
| Consumer resources | Rooftop PV and DNSP storage traces; IASR workbook for EVs and energy efficiency | Kept as separate components or series, not only netted into demand |
| Demand curves | Purchasers (83): demand-side participation price bands | PSIP demand-side technologies |
| Fuel prices | Fuels (125) with price forecasts | Fuel and operating cost data |
| Policies and limits | Constraints (590), Emissions (5), Variables (38) | Standard PSIP requirements where they match; everything else retained and reported |

The plain-language rows above (demand curves meaning Purchasers, forecast prices meaning fuel
prices) were confirmed by the user.

- Interconnector options and their costs come from the IASR workbook's flow path tables,
  and REZ options from its REZ tables.
- Energy efficiency and EVs come from the IASR workbook. If the PLEXOS demand traces already
  include them, the portfolio records that, so they are not counted twice.

### Decisions on mapping (calls made in this design, open to change)

- **Topology:** the 15 subregion Nodes are the planning regions, connected by the flow
  paths. The 19 Zones (14 subregions and 5 regions) carry capacity reserve requirements.
  REZs stay as Constraint records with their IASR augmentation options. Regional results
  for the acceptance checks are sums over subregions.
- **Dated values:** build costs, fuel prices and other year-dependent values become PSIP
  time series keyed by year, following the `inv_capex` pattern in the compatibility gate.
  PSY component fields that hold a single value take the value in force at the start of the
  horizon. The full history stays in the source records.
- **Committed and retiring units:** these are existing PSY components with a dated
  availability series and a status label (existing, committed, anticipated, retiring). That
  lets the comparison against NEM Generation Information line up by status, and keeps
  capacity counted once.

### Placeholder assumptions (decided)

When a PSY or PSIP constructor needs a value that neither the PLEXOS model nor the workbook
provides, the adapter uses a documented placeholder rather than leaving the object unmapped.
Examples: debt fraction 0 and return on equity equal to the WACC; unconstrained ramp limits.

- Each placeholder is defined once in code, with its value and the field it fills.
- The coverage report marks every value filled this way as a placeholder, naming the object.
- An ADR lists every placeholder.

This is not a silent default: the anti-goal is a missing value disappearing without a trace,
and a placeholder is always visible in the report.

### Coverage report

Building the portfolio produces a report keyed to source records with four parts: inputs
retained, inputs mapped to PSY/PSIP objects, values filled by placeholders, and inputs left
unmapped with the reason. The
report must never claim that a constraint is represented when it is only retained.

### Acceptance

- Generated-fixture tests cover source identity (the same IDs in different scenarios,
  properties sharing names across collections, multiple memberships), missing values, date
  overlaps, bands, tags, variable references, existing capacity counted once, candidates
  contributing no existing capacity, MW and MWh kept apart, and explicit unit and calendar
  conversions.
- The built portfolio survives a PSIP JSON round trip.
- A local real-data check builds the Step Change portfolio from the cache and compares:
  - existing capacity per region and technology against AEMO's published existing generation
    figures (IASR workbook or NEM Generation Information);
  - annual demand totals per region against the 2025/2026 ESOO forecasts for Step Change.
  The builder chooses the exact reference files and tolerances, and records them with the
  results. Differences are explained, not tuned away.

## Constraints common to both parts

- Project standards in `AGENTS.md` apply: Runic, explicit `return`, reference-style
  docstrings, `@chain` for DataFrame work, DuckDB.jl for database access, no em-dashes.
- Any departure from AEMO's ISP methodology, or from PLEXOS semantics, is recorded in an ADR.
- The rationale for splitting ingestion and portfolio into separate packages goes in an ADR.
- `CHANGELOG.md` `[Unreleased]` stays current.
- Only one Julia job runs at a time on this machine.

## Left to the builder

- Function and type names beyond `AEMInvestmentPortfolio` and the package name.
- XML parsing approach and memory strategy, within the constraints above.
- How the Portfolio package finds the ISP database file from Cache's configuration.
- The order of work and how it is split into PRs.
- Choice of reference files and tolerances for the real-data checks.
- Whether user documentation pages are written in this work.
