# ISP ingestion and investment portfolio: scoping and work breakdown

Date: 7 November 2026. Branch: `isp2026-portfolio`, based on `origin/v0.2` with the nine ISP
commits rebased onto it (previously stacked on `isp2026-plexos-parsing` at `beed0c9`). This
document re-plans the task sequence of
`2026-10-28-isp-investment-portfolio.md` against
`2026-11-04-isp-ingestion-and-portfolio-design.md`. The architecture is unchanged: Part 1
extends AEMData, Part 2 is a new `AustralianElectricityMarketsPortfolio` package wrapping a
genuine `PSIP.Portfolio`.

## Verified state

| Item | Finding |
| --- | --- |
| Cache contract | `~/.nemdb_cache/ISP/2026/isp.duckdb` (825 MB) has 81 scenario XML tables (27 x 3), 726 distinct trace tables, 745 trace file catalogue entries, 1,683 Data File references and 0 row-count failures. Matches `isp2026-cache.md`. |
| Schemas | `accelerated_transition`, `slower_growth`, `step_change`, `traces`, `cache_meta`. There is no `iasr` schema yet, so the workbook is not ingested. |
| Source provenance | `isp.sources.json` lists 5 archives for release `2026-09-28` with `source_url`, `revision`, `sha256`, `retrieval_method`, and paths. It has no IASR workbook entry. |
| Archives | The Store volume is not mounted, so the original ZIPs and the Python-vs-Julia parity check are unavailable right now. The cache is enough for fixtures, source-layer work and Part 2 scoping. |
| AEMData code | `isp2026/xml.jl` reads 13 of 27 tables (`ISP_XML_TABLES`) and `load_isp_xml!` writes them into an `AEMDB` schema. `isp2026/properties.jl` (314 lines) holds `resolve_properties` and its helpers. |
| Part 2 code | No `AustralianElectricityMarketsPortfolio/` directory, workspace entry or CI workflow. The Task 1 gate exists at `test/isp_portfolio/compatibility/` and is committed as `3516484`. |
| Dependency set | Copied root manifest resolves PowerSystems 5.12.4, InfrastructureSystems 3.6.3 and the PSI fork `fc30a298afb314d563488db852387e145ec97f9a`. PSIP is not in the root manifest, as required. |
| Base currency | `isp2026-portfolio` is 9 commits ahead of `origin/v0.2` on a linear history. The rebase resolved conflicts in the Data module, `Project.toml`, `test/runtests.jl` and `CHANGELOG.md`. |

## Reconciliation of the 28 October plan

- Task 1 (PSIP/PSINV compatibility gate) stands as delivered. Its 12/12 result and the PSIP
  revision `c1150d6eadaa3d28f36575e7232d8d77dc722cca` are the contract for Part 2.
- Tasks 2 to 4 are superseded. Their source records, standard-object materialisation and
  coverage-report content return as P2b to P2e under the separate package.
- The optional-extension decision is replaced by the package dependency boundary. No PSIP
  dependency is added to Cache, Data, AEM or Simulations.
- `resolve_properties`, `_assert_properties_exist`, `_property_defaults`, `_matching_timeslice_ids`,
  `_self_named_month`, `_month_expression_matches` and `_sql_string_list` move from Data to
  Portfolio. The four PLEXOS precedence fixes still travel with them.

## Part 1: AEMData ingestion

All tasks keep the Data package free of AEM, Simulations, PSY and PSIP dependencies. Tests use
generated fake archives and never touch the network. Extracted files go on disk, not `/tmp`.

### P1a: Release list, archive folder and 403-safe download

- Add a built-in, versioned 2026 release record: the five archives, each with source URL,
  revision, SHA-256, canonical filename and kind, seeded from `isp.sources.json`. The IASR
  workbook becomes a sixth entry when P1d is picked up.
- Add an ISP populate entry point taking a local archive folder. Use archives already present;
  attempt a plain HTTP request only for missing ones; on refusal throw one error listing every
  missing archive's browser link, exact filename and destination folder; verify SHA-256 before
  use and treat a mismatch as a release-list error.
- Decide canonical names by matching archives on hash (browser downloads arrive as
  `2026 ISP Model (1).zip`).
- Files: new `AustralianElectricityMarketsData/src/isp2026/release.jl` and `download.jl`;
  export from the Data module.
- Reuse: `_fetch_with_retry`, `_download_and_cache` and the retry/backoff conventions in
  `nemweb_load/download.jl`.
- Verify: `julia --project=AustralianElectricityMarketsData -e 'using Pkg; Pkg.test()'` with
  new fixture tests for present archive, missing archive (403 message content), hash mismatch,
  and canonical-name matching. No network in tests.

### P1b: All 27 XML tables, standalone database and load validation

- Extend `ISP_XML_TABLES` to the 27 observed tables from `isp2026-inventory.md`.
- Replace the `AEMDB`-schema loader with one that builds
  `~/.nemdb_cache/ISP/2026/isp.duckdb` from the cache root in `HiveConfiguration`. Build to a
  temporary file and rename only after validation, so a failed load leaves no half database.
- Write `cache_meta.xml_tables` (scenario, table, source path/hash, columns, record count).
  Compare every source record count with the imported count.
- Make the call idempotent: skip a cached release unless `force_new = true`; `force_new`
  rebuilds the whole file.
- Files: `isp2026/xml.jl` (loader rewrite), new `isp2026/cache.jl`; tests in
  `AustralianElectricityMarketsData/test/isp2026.jl` and the fixture.
- Verify: Data suite. Fixture builds a two-scenario database from a generated XML and asserts
  27 tables per scenario, `cache_meta.xml_tables`, row-count equality, idempotence, `force_new`
  and atomic failure (a deliberately bad fixture leaves no file).
- Migration note: keep `read_plexos_xml` as the parser; `load_isp_xml!` is removed rather than
  left as a second writer (one writer per dataset).

### P1c: Trace CSVs, Data File references and `cache_meta`

- Load each CSV once into `traces` as `f_<sha256>`, all columns `VARCHAR`, header preserved,
  including date-key and `Year`-key layouts.
- Resolve Data File references through `t_text` filename values joined to `t_tag` Data File
  objects and `t_membership`, as `extract_isp_cache.py` does.
- Write `cache_meta.trace_files`, `cache_meta.trace_references` and
  `cache_meta.row_count_checks`; create each scenario's `trace_bindings` view.
- Fail the build if any reference does not resolve or any row count differs.
- Files: new `isp2026/traces.jl`; test fixture gets a small CSV set with a shared-bytes pair
  and a missing-reference case.
- Verify: Data suite assertions for 726-style dedup on the fixture, shared table reuse,
  bindings view, and zero unresolved references.

### P1d (follow-up, out of this scope): IASR workbook as raw cells

The workbook was deferred on 7 November 2026. When it is picked up:

- Add the workbook as the sixth release entry and download it under the same rules.
- Store every sheet's cells in an `iasr` schema keyed by sheet name, row and column, value as
  text. Locate no tables and interpret nothing in Data.
- Read the OOXML parts with the existing `ZipArchives` and `XML` dependencies, keeping values
  raw and avoiding a new dependency; handle shared strings and sheet names.
- Files: `isp2026/iasr.jl`; fixture is a tiny generated `.xlsx`/`.xlsm` ZIP.
- Verify: Data suite asserts sheet names, cell coordinates, text values and the provenance row.

### P1e: Real-data parity check (local only)

- Compare the Julia-built database with the Python-built one: schemas, tables, columns, row
  counts and identical values, as the spec requires.
- Blocked until the Store volume holding `.../isp2026/2026-09-28/` is mounted. Record the
  comparison command and result in the cache notes.

## Part 2: `AustralianElectricityMarketsPortfolio`

### P2a: Package scaffold and CI

- Create `AustralianElectricityMarketsPortfolio/` with Project.toml, `src/`, `test/` and a test
  project, and a `TestPortfolio.yml` workflow following `TestData.yml`.
- The package is **standalone**, with its own `Manifest.toml`, not a root `[workspace]` member:
  PSIP requires HTTP 1.x and the workspace resolves 2.7.1, so a shared manifest would force every
  package down to HTTP 1.x. Recorded as ADR 0088. Consequence for the plan: the workspace has four
  members, the Portfolio project is instantiated separately.
- Pin PSIP through `[sources]` to revision `c1150d6eadaa3d28f36575e7232d8d77dc722cca`; PSY and IS
  are pinned by revision to the same commits as the root manifest and resolve to the same versions
  (PSY 5.12.4, IS 3.6.3). No PSI or PSINV runtime dependency.
- Decide the fate of `test/isp_portfolio/compatibility/`: relocate the gate into the package's
  test environment or keep it as the isolated dependency proof. Recommend keeping the
  isolated gate and adding the package's own integration group separately.
- Verify: package loads; `Pkg.test` runs an Aqua/empty group; CI workflow paths include the new
  package plus Cache.

### P2b: Source layer and property resolution

- Move the resolution helpers from Data into the Portfolio package and delete them from Data in
  the same PR.
- Implement `ISPSourceData` records preserving scenario, class, collection, membership,
  property, date, band, tag, timeslice and Variable/Data File scoping, with originals alongside
  interpreted values.
- Implement `read_isp_source(path; scenario)` opening the cache read-only and never querying
  physical trace arrays.
- Lazy trace handles only; no trace arrays loaded at read time.
- Tests: colliding IDs across scenarios, same property name in different collections, multiple
  memberships, missing values, overlapping dates, bands, tags, indirect Variable/Data File
  references.
- Verify: package test group `isp_portfolio_source` plus the existing Data `isp` group run in
  the Data package after the move; assert the database file is unchanged (open read-only).

#### P2b design

Grounded by reading the real cache (`~/.nemdb_cache/ISP/2026/isp.duckdb`, read-only) and by
`AustralianElectricityMarketsData/src/isp2026/properties.jl`.

**Package boundary.** The Portfolio package does not depend on Data, so the two helpers it needs
move to Cache, which both packages already depend on:

| Helper | From | To |
| --- | --- | --- |
| `isp_cache_path(config)` | `…Data/src/isp2026/cache.jl` | `…Cache/src/isp_cache.jl` |
| `isp_scenario_schema(scenario)` | `…Data/src/isp2026/xml.jl` | `…Cache/src/isp_cache.jl` |

Data keeps both names by re-exporting them with `@doc (@doc AustralianElectricityMarketsCache.f) f`,
so its public API does not change.

**Files.**

| Path | Role |
| --- | --- |
| `…Cache/src/isp_cache.jl` | `isp_cache_path`, `isp_scenario_schema` |
| `…Portfolio/src/isp_source.jl` | source records, `read_isp_source`, catalogue, trace handles |
| `…Portfolio/src/isp_properties.jl` | `resolve_property`, `resolve_properties`, precedence rules |
| `…Portfolio/test/isp_source_fixture.jl` | DuckDB cache fixture written by the Portfolio tests |
| `…Portfolio/test/isp_source.jl` | the `isp_portfolio_source` test group |
| `test/fixtures/isp2026_fixture.jl` | the XML fixture, moved out of the Data test directory |

`AustralianElectricityMarketsData/src/isp2026/properties.jl` is deleted; its two testsets move
into the Portfolio package.

**Source records.** Every value keeps its PLEXOS identity and its scoping, with the stored text
alongside the interpreted value.

```julia
struct ISPSourceTag
    object_id::String
    object_name::String
    class_name::String          # "Timeslice", "Data File" or "Variable"
    action_id::Union{String,Missing}
end

struct ISPSourceRecord
    scenario::Symbol
    data_id::String
    membership_id::String
    collection_id::String
    collection_name::String
    class_id::String
    class_name::String
    object_id::String
    object_name::String
    category::String
    property_id::String
    property_name::String
    value::Union{Float64,Missing}      # TRY_CAST of the stored value
    raw_value::Union{String,Missing}    # the stored value as text
    text_value::Union{String,Missing}   # the text attached to the same data row
    date_from::Union{DateTime,Missing}
    date_to::Union{DateTime,Missing}
    band::Int
    tags::Vector{ISPSourceTag}
end

struct ISPTimeSlice
    object_id::String
    name::String
    is_active::Bool
    include_values::Vector{String}   # the stored Include values
    include_texts::Vector{String}    # the stored Include text expressions
end

struct ISPTraceHandle
    scenario::Symbol
    data_file_object_id::String
    data_file_object_name::String
    relative_path::String
    table_schema::String
    table_name::String
    source_sha256::String
    source_path::String
end

struct ISPSourceData
    scenario::Symbol
    path::String
    objects::DataFrame        # object_id, name, class_name, category
    collections::DataFrame    # collection_id, collection_name, parent_class_name, child_class_name
    properties::DataFrame     # property_id, name, collection_id, default_value, is_multi_band, max_band_id
    memberships::DataFrame    # membership_id, parent_object_id, collection_id, child_object_id, class_name
    records::Vector{ISPSourceRecord}
    timeslices::Vector{ISPTimeSlice}
    trace_handles::Vector{ISPTraceHandle}
    trace_by_data_id::Dict{String, ISPTraceHandle}
end
```

**Reads.** `read_isp_source(path; scenario)` opens the DuckDB file with `readonly = true`, reads
the `t_*` tables of the scenario schema and `cache_meta.trace_references`, and closes the
connection. It never selects from a `traces` table. `isp_scenarios(path)` lists the
scenario schemas in a cache. `read_isp_trace(path, handle)` opens the file read-only again and
returns one trace table, so trace arrays are loaded only when asked for.

The column names below are those of the real cache, read from `information_schema.columns`:
`t_object(object_id, class_id, name, category_id)`, `t_class(class_id, name)`,
`t_category(category_id, name)`, `t_collection(collection_id, name, parent_class_id,
child_class_id)`, `t_property(property_id, name, collection_id, default_value, is_multi_band,
max_band_id)`, `t_membership(membership_id, parent_object_id, collection_id, child_object_id,
child_class_id)`, `t_data(data_id, membership_id, property_id, value)`, `t_date_from(data_id, date)`,
`t_date_to(data_id, date)`, `t_band(data_id, band_id)`, `t_tag(data_id, object_id, action_id)` and
`t_text(data_id, class_id, value)`. Every column holds text, so the numeric and timestamp
interpretations happen in SQL: `TRY_CAST(value AS DOUBLE)`, `CAST(date AS TIMESTAMP)` and
`COALESCE(TRY_CAST(band_id AS INTEGER), 1)`.

`cache_meta.trace_references(scenario, data_file_object_id, data_file_object_name,
filename_data_id, relative_path, table_schema, table_name, source_sha256, source_path)` holds one
row per Data File reference, and `cache_meta.trace_files(scenario, family, filename, source_path,
source_sha256, source_bytes, table_schema, table_name, row_count, column_count, columns_json)` one
row per trace table, with the shared files recorded under the scenario `missing`. A trace table
holds the columns `Year`, `Month`, `Day` and one column per hour or interval.

**Trace scoping.** A record is linked to a trace in one of two ways, both preserved in the source:

- directly, when the record is tagged to a `Data File` object;
- indirectly, when the record is tagged to a `Variable` object whose own `Profile` record is
  tagged to a `Data File` object. In the real cache a constraint's `Generation Coefficient` record
  is tagged to a Variable, whose `Profile` record is tagged to a Data File, whose `Filename` text
  names the trace.

`ISPSourceData.trace_by_data_id` resolves both forms to a handle, keyed by the data row id of the
record that points at the trace, including the `Filename` rows themselves.

**Property identity.** A property name is not unique within a class. In the real cache 289
(class, property name) pairs map to more than one `property_id`, and 126 objects carry the same
property name under two different `property_id`s. Collection names repeat too: three distinct
collections are named `Generators`. Resolution therefore keys on `property_id`, and the helpers
are:

```julia
isp_property_catalogue(source; class = nothing) -> DataFrame
resolve_property(source, property_id, horizon_start; band = 1) -> DataFrame
resolve_properties(source, class, properties, horizon_start; band = 1, collection_id = nothing) -> DataFrame
```

`resolve_property` returns one row per object of the property's class, with `object_id`,
`object_name`, `category`, `value`, `data_id` and `is_default`. `resolve_properties` returns the
wide table with `name`, `category` and one column per requested property. It throws an
`ArgumentError` when a property name is unknown for the class, and also when it maps to more than
one `property_id`, listing the candidates and their collection ids; `collection_id` narrows the
choice.

**Precedence.** The four PLEXOS fixes travel with the move, and the rules are applied to the
records rather than in SQL:

1. a record applies when the object is the child of its membership;
2. the date window is `date_from <= horizon_start` and `date_to >= horizon_start`, with a missing
   `date_from` ranking last;
3. the band must equal the requested band, and a record with no band is band 1;
4. a record applies when it carries no tag, or when it is tagged to an active `Timeslice` whose
   months contain the horizon month. A timeslice matches by its `Include` text expression
   (`M4-10`, `M1-3,11,12`), or, when it has none, by its own `M<n>` name. An active timeslice with
   neither is a genuine gap and makes resolution throw, naming the timeslice. An inactive
   timeslice is excluded before any expression is read. A record tagged to a Data File or a
   Variable is not a scalar value and never applies;
5. among the applicable records for an object and property, a timeslice-matched record outranks an
   untagged one, and a later `date_from` outranks an earlier one.

A record whose stored value is not numeric is not a candidate, and a property with no applicable
record falls back to its `default_value`. A property that declares no default and has no
applicable record resolves to `missing`, not to zero: an unresolved input must never become a
number by accident.

**Tests.** The Portfolio package writes its own DuckDB fixture, so it needs no Data dependency for
the source layer. The XML fixture moves to `test/fixtures/isp2026_fixture.jl` and is included by
the Data and Portfolio runners, so the precedence tests run against the same XML-derived cache as
before.

**Work split.**

| Step | Content |
| --- | --- |
| B1 | Cache gains `isp_cache_path` and `isp_scenario_schema`; Data re-exports them; the XML fixture moves to `test/fixtures/` |
| B2 | Done: Portfolio source layer, DuckDB fixture, trace handles, the `isp_portfolio_source` group |
| B3 | Done: Portfolio resolution over the records (`isp_portfolio_properties` group); `…Data/src/isp2026/properties.jl` deleted; the two Data testsets moved |

### P2c: Wrapper, accessors and coverage report

- Add top-level `AEMInvestmentPortfolio{P}` in the package module, `ISPImportReport`, a
  placeholder registry (each placeholder defined once with value and field), and accessors
  `investment_portfolio`, `isp_source`, `isp_coverage`.
- Report four parts keyed to source records: retained, mapped, placeholder-filled, unmapped
  with reason. Never claim a constraint is represented when only retained.
- Verify: fixture tests assert `investment_portfolio(case) === wrapped`, report rows cite
  source identifiers, placeholders appear by name, and the report distinguishes retained from
  mapped.

### P2d: Materialise standard PSY and PSIP objects

- Implement `build_isp_portfolio(source; effective_at, topology_map, calendar, financial_basis)`
  returning a genuine `PSIP.Portfolio` in the wrapper.
- Milestone 1 contents: 15 subregion nodes as planning regions, 5 region zones, 18 lines as
  existing PSY components, generators/batteries/storage as existing devices with dated
  availability and status labels, candidates as `SupplyTechnology`/`StorageTechnology`, trace
  profiles as time series, operational demand as `DemandRequirement`, purchasers as
  demand-side technologies, fuels as cost data, dated values as year-keyed series, matching
  policy constraints as standard requirements, everything else retained and reported.
- Transmission candidates, REZ options, consumer resources and financial parameters from the
  IASR workbook are out of this scope until P1d and P2e land; the coverage report must name
  them as unmapped rather than leave them silent.
- Assign explicit IDs to supplemental attributes (`ExistingDevices` needs one at `c1150d6`).
- Do not depend on printing requirement objects; PSIP's `show` is broken at this revision.
- Verify: the package's PSIP integration group plus a JSON round trip; existing capacity
  counted once, candidates contribute no existing capacity, MW and MWh separate, unresolved
  assumptions produce source-specific diagnostics.

### P2e (follow-up, out of this scope): IASR workbook interpretation

Deferred with P1d. Until then Milestone 1 covers only the PLEXOS model: transmission
augmentation options, REZ options, consumer resources, financial parameters, retirements and
the existing-generation summary from the workbook stay unmapped and explicitly reported.

When picked up:

- Locate and read the flow path augmentation options and cost forecasts (14 flow paths), REZ
  options and costs, energy efficiency, EV uptake and energy, demand-side participation,
  financial parameters, retirements and the existing-generation summary.
- Map options to PSIP transport technologies, and use the existing-generation summary as one
  input to the capacity acceptance check.
- Verify: fixture workbook tests for each table; real-workbook read recorded in the coverage
  report.

### P2f: Real-data Step Change build and acceptance checks

- Build the Step Change portfolio from `~/.nemdb_cache/ISP/2026/isp.duckdb`.
- Compare existing capacity per region and technology with AEMO's published figures and annual
  demand per region with the 2025/2026 ESOO Step Change forecasts. Record reference files,
  tolerances and explanations of differences; do not tune.
- Produce the coverage report for all three scenarios without modifying the cache.
- Verify: local-only command documented in the package; result recorded in the cache notes or
  an ADR. Not part of `Pkg.test` or CI.

## Order and PR strategy

1. The branch is already based on `origin/v0.2`. Run the Data suite and the root
   package-boundary group before P1a to confirm the rebase kept the parser behaviour.
2. P1a, P1b and P1c land on `isp2026-portfolio`. Pushing it supersedes PR #112, whose branch
   remains the unrebased `isp2026-plexos-parsing`; decide at push time whether to close #112 or
   retarget it.
3. P2a can start once P1b's database layout is fixed; P2b needs P1b and P1c; P2c builds on
   P2b; P2d needs P2b and P2c; P2e needs P1d; P2f needs everything.
4. P1e moves `resolve_properties` out of Data; it is one PR on the stacked `isp2026-portfolio`
   branch together with P2b, because removing and adding the same code across a package
   boundary is a single reviewable change.
5. P2a to P2f land on `isp2026-portfolio` as a stacked PR on #112, not on `v0.2` directly.

## Decisions taken

1. Package name: `AustralianElectricityMarketsPortfolio`; wrapper type `AEMInvestmentPortfolio`.
2. Base: `origin/v0.2`. The nine ISP commits were rebased onto it and the branch is linear.
3. IASR workbook: deferred; P1d and P2e are follow-ups.
4. Cache discovery: `isp_cache_path(config::HiveConfiguration)` returns
   `<hive_location>/ISP/2026/isp.duckdb`; Data and Portfolio both call it.
5. Real-data reference files and tolerances for P2f are chosen when that task starts.

## Acceptance carried from the spec

- Generated fixtures cover scenario identity, shared property names, multiple memberships,
  missing values, date overlaps, bands, tags, variable references, existing capacity counted
  once, candidates with no existing capacity, MW/MWh separation, and explicit unit and calendar
  conversions.
- The built portfolio survives a PSIP JSON round trip.
- Real-data capacity and demand checks are explained, not tuned.
- Every placeholder is visible in the coverage report and listed in an ADR.
- No unresolved input silently becomes zero or a default.
