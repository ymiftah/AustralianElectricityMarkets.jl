# AustralianElectricityMarkets.jl

Julia package that fetches AEMO **NEMWEB (MMSDM)** market data into a local Hive-partitioned parquet
cache, queries it with DuckDB, and parses it into **PowerSystems.jl** `System` objects — including
NEM-specific FCAS reserve and offer types.

## Quick start

```julia
db = aem_connect()                                    # AEMDB wrapper over DuckDB.DB
populate(db, :DISPATCHPRICE, Date(2025, 1, 1), Date(2025, 1, 3))
sys = nem_system(db, RegionalNetworkConfiguration())  # or FCASNetworkConfiguration()
```

Cache layout: `~/.nemdb_cache/<TABLE>/archive_month=YYYY-MM-01/*.parquet`. Configuration is entirely
via the `HiveConfiguration` struct (`filesystem = "file" | "s3" | "gs"`) — no env vars are read.

## Commands

```bash
julia --project -e 'using Pkg; Pkg.test()'   # full suite; never hits the network
julia --project=docs docs/make.jl            # Literate + Documenter/Vitepress
pre-commit run -a                            # Runic + markdownlint + yamlfmt (CI "Linting" job)
```

Julia 1.11 workspace: root, `test/`, and `docs/` share one Manifest.

## Layout

| Path | Role |
| --- | --- |
| `src/AustralianElectricityMarkets.jl` | top module: exports, includes, `@doc` re-binding |
| `src/AustralianElectricityMarketsData/` | submodule: NEMWEB download, parquet cache, DuckDB queries |
| `…/nemweb_load/tables.jl` | `_TABLE_SPECS` — one entry per NEMWEB table |
| `…/nemweb_load/column_types.jl` | `COLUMN_TYPES`; unlisted columns silently become `VARCHAR` |
| `src/parser.jl` | time-series setters, bid and FCAS readers |
| `src/fcas/` | FCAS reserve and offer types |
| `src/network_models/region_model.jl` | `RegionModel` submodule: builds the PSY `System` |

## Standards

- **Runic** is the formatter (there is no JuliaFormatter config): 4-space indent, 8-space
  continuation indent on multi-line signatures, trailing commas.
- Every function ends in an explicit `return` (bare `return` for `nothing`-returning functions).
- Docstrings: signature line, one or two sentences of prose, then `# Arguments` / `# Returns` /
  `# Fields` / `# Example`; cross-reference with `` [`name`](@ref) ``.
- **Docstrings are reference documentation, not developer notes.** State what the function does,
  its arguments and its return value — nothing else. A docstring is too long if it runs past a
  short paragraph before the `# Arguments` section. Never put in a docstring: why an approach was
  chosen over another, what failed in testing, empirical findings, history ("used to", "previously",
  "this avoids"), or a narrative of how a bug was found. That reasoning goes in `docs/adr/`.
- **Never reference `docs/adr/` or an ADR number from a docstring, comment, or any user-facing
  text.** ADRs are internal memory for agents, not documentation for users of this package.
- **Keep comments short** — a line or two for the genuinely non-obvious, explaining *what* the
  non-obvious thing is, not the investigation behind it. Do not write paragraph-long
  design-rationale comments.
- Naming: NEMWEB tables/columns stay `SCREAMING_CASE`; Julia API is `snake_case`; private helpers
  are `_`-prefixed; mutating functions take `!`.
- Submodule symbols are exported twice (in the submodule, then re-exported at top level) with
  `@doc (@doc Sub.f) f` so Documenter resolves the docstring from the top-level name.
- DataFrame work uses `@chain`. Parquet access goes through **DuckDB.jl** — `read_hive` returns a
  SQL source fragment you query with `DuckDB.execute`.
- Keep `CHANGELOG.md`'s `## [Unreleased]` current. PRs need a `Closes #`, green tests and Linting,
  and updated docs.
- Scaffolded by BestieTemplate.jl (`.copier-answers.yml`); workflows and pre-commit config are
  copier-managed and can be clobbered on template update.

## Gotchas

- `populate` is idempotent (skips months already cached); pass `force_new = true` after changing a
  `_TABLE_SPECS` column list.
- `read_hive` uses `union_by_name = true`, so old partitions read back `NULL` for newly added columns.
- DuckDB.jl cannot prepare multiple statements at once — issue `INSTALL httpfs` and `LOAD httpfs`
  as separate `DuckDB.execute` calls.
- PSY component types that get serialized must live in the **top-level** module: `IS.get_module`
  only resolves top-level package names, so submodule-nested types break `System` JSON round-trips.
