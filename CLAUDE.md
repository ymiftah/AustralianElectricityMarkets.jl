# AustralianElectricityMarkets.jl

Julia monorepo that turns AEMO **NEMWEB (MMSDM)** market data into **PowerSystems.jl** `System`s and
solves NEM dispatch replicas of them with **PowerSimulations.jl**. It is a Julia 1.11 workspace of
three packages sharing the root `Manifest.toml`; each builds on the one above it:

| Package | Path | Responsible for |
| --- | --- | --- |
| `AustralianElectricityMarketsData` | `AustralianElectricityMarketsData/` | NEMWEB download, Hive-partitioned parquet cache, DuckDB connection and raw queries, ISP inputs. No PowerSystems dependency. |
| `AustralianElectricityMarkets` | repo root (`src/`) | Builds the PSY `System`: network configurations, readers, time-series/bid/limit setters, NEM-specific FCAS reserve and offer types, generic constraints, interconnector losses. Re-exports the Data package's API. |
| `AustralianElectricityMarketsSimulations` | `AustralianElectricityMarketsSimulations/` | NEMDE replication in PSI: `AbstractNEMDispatch` device formulations (batteries included), FCAS market and trapezium formulations, NEM constraint formulations, per-interval inputs and preprocessing, pre-flight checks. |

## Quick start

```julia
db = aem_connect()                                    # AEMDB wrapper over DuckDB.DB
populate(db, :DISPATCHPRICE, Date(2025, 1, 1), Date(2025, 1, 3))
sys = nem_system(db, RegionalNetworkConfiguration())  # energy-only regional system
sys = nem_system(db, ConstrainedNetworkConfiguration(); date_range = start:Minute(5):stop)
                                                      # + FCAS services, generic constraints, losses
```

Cache layout: `~/.nemdb_cache/<TABLE>/archive_month=YYYY-MM-01/*.parquet`. Configuration is entirely
via the `HiveConfiguration` struct (`filesystem = "file" | "s3" | "gs"`) — no env vars are read.

## Commands

```bash
julia --project -e 'using Pkg; Pkg.test()'                                         # root suite
julia --project=AustralianElectricityMarketsData -e 'using Pkg; Pkg.test()'        # Data suite
julia --project=AustralianElectricityMarketsSimulations -e 'using Pkg; Pkg.test()' # Simulations suite
julia --project=docs docs/make.jl            # Literate + Documenter/Vitepress
pre-commit run -a                            # Runic + markdownlint + yamlfmt (CI "Linting" job)
# Real-data integration suite: local only (not in Pkg.test or CI), reads ~/.nemdb_cache
julia --project=AustralianElectricityMarketsSimulations/test \
    AustralianElectricityMarketsSimulations/test/real_data/runtests.jl [hive_location]
```

All three suites run on generated mock parquet data and never hit the network; CI runs all three.

**Run only the test groups your change touches.** The root and Simulations runners take group
names (listed in `TEST_GROUPS` at the top of each `runtests.jl`; no arguments runs everything):

```bash
julia --project -e 'using Pkg; Pkg.test(; test_args = ["fcas", "timeseries_setters"])'
julia --project=AustralianElectricityMarketsSimulations/test \
    AustralianElectricityMarketsSimulations/test/runtests.jl fcas_market preprocessing
```

Pick the groups whose test file covers the source you edited (e.g. `src/fcas/` → `fcas`,
`fcas_scaling`, `fcas_service`; `…Simulations/src/fcas_market.jl` → `fcas_market`). Run the full
suites only for cross-cutting changes (shared fixtures, runner, dependencies, a change in one
package that the next one consumes) or before opening a PR. Use absolute paths when launching Julia
from a backgrounded subshell. Shared fixtures: `AustralianElectricityMarketsData/test/mock_data.jl`
(all three suites), `test/integration/pscb_*.jl` (root and Simulations), and
`…Simulations/test/toy_fixture.jl` / `template_helpers.jl`; each runner loads its fixtures up
front, so every group runs on its own.

## Where things live

| Path | Role |
| --- | --- |
| `…Data/src/nemweb_load/tables.jl` | `_TABLE_SPECS` — one entry per NEMWEB table |
| `…Data/src/nemweb_load/column_types.jl` | `COLUMN_TYPES`; unlisted columns silently become `VARCHAR` |
| `src/AustralianElectricityMarkets.jl` | exports, includes, `@doc` re-binding of Data/`RegionModel` names |
| `src/network_models/` | `NetworkConfiguration` interface; `RegionModel` submodule builds the `System` |
| `src/fcas/`, `src/constraints/` | FCAS types/bids/scaling/`FCASService`; `GenericConstraint` and its terms |
| `…Simulations/src/nem_dispatch*.jl` | `AbstractNEMDispatch` formulations and `set_nem_dispatch_models!` |
| `…Simulations/src/check/<what_is_checked>.jl` | pre-flight checks run before a build |
| `…Simulations/src/psi_compat.jl` | shims over the pinned PowerSimulations fork |
| `docs/adr/` | architecture decisions — design rationale goes here |
| `docs/superpowers/plans/` | implementation plans; follow-up work is recorded here or in an ADR |

## Standards

- **Runic** is the formatter, run it at the end of a task.
- Every function ends in an explicit `return` (bare `return` for `nothing`-returning functions).
- Docstrings: signature line, one or two sentences of prose, then `# Arguments` / `# Returns` /
  `# Fields` / `# Example`; cross-reference with `` [`name`](@ref) ``.
- **Docstrings are reference documentation.** State what the function does, its arguments and its
  return value, in at most a short paragraph before `# Arguments`. Design rationale, test findings
  and history go in `docs/adr/`.
- **Docstrings, comments and user-facing text stand on their own**: they never cite `docs/adr/` or
  an ADR number. ADRs are internal memory for agents, not documentation for users of this package.
- **Comments are one or two lines**, reserved for the genuinely non-obvious, saying *what* the
  non-obvious thing is.
- Naming: NEMWEB tables/columns stay `SCREAMING_CASE`; Julia API is `snake_case`; private helpers
  are `_`-prefixed; mutating functions take `!`.
- Names exported from the Data package or the `RegionModel` submodule are re-exported at the top
  level with `@doc (@doc Sub.f) f` so Documenter resolves the docstring from the top-level name.
- DataFrame work uses `@chain`. Parquet access goes through **DuckDB.jl** — `read_hive` returns a
  SQL source fragment you query with `DuckDB.execute`.
- Keep `CHANGELOG.md`'s `## [Unreleased]` current. PRs need green tests and Linting,
  and updated docs.
- Scaffolded by BestieTemplate.jl (`.copier-answers.yml`); workflows and pre-commit config are
  copier-managed and can be clobbered on template update.
- No em-dashes in prose.

## NEM correctness

Any change to the optimisation model (a dispatch, FCAS, constraint or loss formulation in
`…Simulations/src/`, or the NEM types, bids and limits it reads from `src/`) is validated against
AEMO's official documentation through the `nem-expert` skill. Load it when planning the change
and again when reviewing it; every variable bound, constraint and cost term needs a matching
AEMO source. Where the code departs from AEMO, record the departure in an ADR.

## Gotchas

- `populate` is idempotent (skips months already cached); pass `force_new = true` after changing a
  `_TABLE_SPECS` column list.
- `read_hive` uses `union_by_name = true`, so old partitions read back `NULL` for newly added columns.
- DuckDB.jl cannot prepare multiple statements at once — issue `INSTALL httpfs` and `LOAD httpfs`
  as separate `DuckDB.execute` calls.
- PSY component types that get serialized must live in the **top-level** `AustralianElectricityMarkets`
  module: `IS.get_module` only resolves top-level package names, so submodule-nested types break
  `System` JSON round-trips.
- Simulations depends on a **pinned PowerSimulations fork** (`[sources]` in its `Project.toml`);
  check PSI behaviour against that revision, not upstream.
