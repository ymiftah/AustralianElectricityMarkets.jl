# Model build time audit

Static review of where `PSI.build!` (and the steps around it) spend time when building the NEM
replication template. The HiGHS solve is fast by comparison, so build time dominates.

## Status and caveats

- Static review only. Julia was not installed in the review environment, so **nothing was profiled
  or measured**. The impact ratings are estimates from redundant work visible in the code.
- Claims about PowerSystems (PSY), InfrastructureSystems (IS) and PowerSimulations (PSI) internals
  are unverified. Check them against the versions pinned in `Manifest.toml` and the PSI fork in
  `AustralianElectricityMarketsSimulations/Project.toml`.
- Replication builds a single interval, so per-`t` loops are short. Per-call fixed costs
  (time-series reads, container lookups, `get_component`) dominate over loop length.
- No benchmark, build-time note or performance record exists in `docs/adr`, `CHANGELOG.md` or the
  tests, so nothing guards build time against regression.

Line numbers refer to the repository at the time of review and will drift.

## Recommended order

1. Add a timing harness around `_replication_model` (`replication/pipeline.jl`) and split the time
   by construct stage and by service or device type. Profile with `@profview PSI.build!(model)`,
   and separately `filter_buildable_generic_constraints` plus `add_nem_constraints!`.
2. Pure caching and hoisting with no behaviour change: A1 to A4, B1, B2.
3. Changes that remove model objects (results should be identical, rerun the tests): A5 to A7.
4. Defer A9 (tie-break chain). It changes the AEMO formulation and needs a NEM correctness review
   and an ADR first.
5. Add a build-time benchmark or test so the gains are kept.

## A. Model construction (`AustralianElectricityMarketsSimulations/src/`)

### Highest impact

| ID | Where | Smell | Fix |
| --- | --- | --- | --- |
| A1 | `fcas_market.jl:241,443,666-668,772-773,1002-1003` | FCAS time series are re-read and re-scaled many times per (device, service). `_fcas_series` reads the trapezium plus up to four scaling series and validates each step. `_fcas_enabled_mask` calls it again and re-reads `initial_mw`, `agc_status` and availability. The argument stage, the model stage, the joint-ramping builder and the storage "both sides" path each repeat this. A device in N services pays N times, although its telemetry is identical across services. | Compute one record per (service, device): trapeziums, curves, enabled mask, ramp caps. Share it between both construct stages (for example in `container.ext`). Cache per-device telemetry reads across services. |
| A2 | `fcas_market.jl:252` | `_fcas_series` always builds the offer curves. Most callers discard them (`trapeziums, _ = ...` at `:772`, `:1002`, `:810`, `:1057`). | Split into a trapezium-only function and a curves function. |
| A3 | `fcas_market.jl:967-974` | Per `(device, t)`, `_device_regulation_target` iterates `PSY.get_services`, does `has_container_key` and `get_expression`, and fills an untyped `targets = []`. Called twice per cell (raise and lower). | Resolve the target expression once per device, index by `t`. Type the vector. |
| A4 | `fcas_market.jl:132-168` | `_fcas_energy_terms` allocates a vector of `(DataType, Float64)` per call. Each term does `has_container_key` and `get_variable(container, var_type(), ...)` with a runtime `DataType`, which dispatches dynamically, per `(device, t)` for 2 to 4 expressions. | Resolve `(variable array, multiplier)` once per device and run the check once. Keep only `add_to_expression!` in the loop. |

### Model size created for nothing

| ID | Where | Smell | Fix |
| --- | --- | --- | --- |
| A5 | `fcas_market.jl:576-582,1006-1008,1061-1063,1075-1077` | Disabled (device, t) cells (failed pre-conditions) still get three slack variables (priced in the objective), up to three vacuous `0 <= 1` rows, a pinned capacity variable and band variables. | Create slacks only for enabled cells and have `_fcas_slack_term` return `0.0` otherwise. |
| A6 | `fcas_market.jl:882-888`, `devices/mnsp_links.jl:135-143` | Offer bands with zero width get a variable (`upper_bound = 0`), a term in `sum(bands) == capacity_var` and an objective term. NEMWEB offers have 10 bands and most carry 0 MW. Disabled device-intervals also get bands. | Skip bands where `x[i+1] == x[i]`. Skip the device-interval when its capacity is disabled. Likely the largest variable count in the FCAS part. |
| A7 | `nem_constraints.jl:430`, FCAS and ramping builders | `JuMP.@constraint(jm, 0.0 <= 1.0)` vacuous rows are real JuMP and MOI rows and reach HiGHS as empty rows. | Try one vacuous row per container, assigned to every vacuous cell. Check PSI's dual read-back first, because it broadcasts over the whole container. |

### Medium impact

| ID | Where | Smell | Fix |
| --- | --- | --- | --- |
| A8 | `nem_constraints.jl:103-157,216-241,249-267` | Many `GenericConstraint`s, each its own `ServiceModel`. Per term: `PSY.get_component(PSY.Device, sys, name)` (an abstract-type lookup across all type containers), a repeat of the same lookups in `_warn_absent_fcas_services`, and `get_component(FCASService)`, `fcas_service_name`, `has_container_key`, `get_expression` and `axes` per device. Each constraint also has its own RHS parameter container and small containers. | Build a name to device `Dict` once per build. Memoise service resolution per `(service name, bid type)` and variable arrays per component type. Check whether per-constraint PSI overhead dominates afterwards. |
| A9 | `nem_tie_break.jl:62-80,105-120` | Tie-break is O(n²) in tied bands. Every pair of tied bands from different units gets two slack variables, a constraint and an objective term. A region with hundreds of bands at one price (0 or the price floor) produces tens of thousands of pairs, which hurts the solve as well. `_tie_break_bands` also calls `get_component`, `get_area` and `_get_pwl_data` per `(device, t)`. | Hoist per-device lookups. A consecutive-pair chain would be O(n) but changes the AEMO formulation: review with the `nem-expert` skill and record an ADR before doing it. |
| A10 | `nem_dispatch.jl:164-171` and call sites in `psi_compat.jl:222`, `nem_constraints.jl:531`, `fcas_market.jl:581` | `PSI.add_to_objective_invariant_expression!(container, slack[name, t] * coefficient)` allocates a fresh `AffExpr` per call. | Check whether the pinned fork has a `(container, var, coeff)` method. If not, add terms directly with `JuMP.add_to_expression!`. |
| A11 | `nem_dispatch.jl:324-332,392-400,452-482`, `nem_dispatch_storage.jl:195` | The `_ts_parameter_accessor` closure calls `get_parameter_column_refs(param_container, name)` per `(name, t)` and allocates `ref * multiplier`. The ramp rows call it twice per cell. `_check_dispatch_envelope` calls it three more times per cell plus `JuMP.value`, and builds three covered-name `Set`s. | Fetch column refs and multiplier arrays once per name outside the `t` loop. |
| A12 | many `base_name = "...{$name,$t}"` sites | Interpolated variable names allocate a string and a name-dictionary insert per variable. | Consider `JuMP.set_string_names_on_creation(jm, false)` for replication runs, or drop names. This costs readable LP exports, and PSI result export may use names, so check first. |
| A13 | `devices/interconnector_losses.jl:155-190,268-311,436-450`, `devices/mnsp_links.jl:36-50` | `_area_demand` does a full-horizon `get_time_series_values` per load, with two or three `has_time_series` calls each. `_demand_at` allocates a `Dict` per `t`. `loss_segments` is recomputed per `(device, t)`. `get_time_series_keys` is read three times per device, with `unique(filter(...))` allocations. | Read series keys once per device. Hoist demand to a vector indexed by area. Compute `loss_segments` once per `t`. |
| A14 | `nem_dispatch.jl:130-135,517-533`, `:565` | `nem_dispatch_participants` and `_uncovered_names` call `get_default_time_series_names` and `has_time_series` per name per device. The `skip_uncovered` filter closure reruns this on every device. | Resolve names once per concrete type. Quick-reject on `has_time_series(device, SingleTimeSeries)`. |
| A15 | `devices/mnsp_links.jl:96-158` | Untyped `Dict`s keyed by direction, a `Dict` per `t`, per-element `@variable` calls with name strings, and an `AffExpr` cost per band set. Few devices, so bounded. | Use NamedTuples or 2-tuples. Preallocate the cost expression. |

### Low impact

- Market price cap is looked up per `t` and per slack family, each time doing `findfirst` over a
  `Vector{Pair}` and a settings `get` (`nem_constraints.jl:37-47`, `nem_dispatch.jl:381`,
  `psi_compat.jl:219`). Precompute once per container.
- `PSI.DecisionModel` is built with defaults (`replication/pipeline.jl:206`). Check whether the
  pinned fork exposes `check_numerical_bounds`, `store_variable_names` or export options and what
  they default to.

## B. Pre-flight checks and root package (`src/`)

| ID | Where | Impact | Smell | Fix |
| --- | --- | --- | --- | --- |
| B1 | `src/constraints/resolve.jl:22-30,57-60`, `src/constraints/build.jl` ~299-305 | High | `_region_devices` flattens all generators and storage and checks `get_name(get_area(get_bus(d)))` per device, with `_offers_fcas` (up to ~10 `has_time_series` calls) per load when `loads = true`. It runs twice per `RegionTerm` row with no cache. There are only about 5 regions times ~11 service keys of distinct inputs. `build.jl:67` (`_key_missing`) also does `get_component` per term row. | Memoise `Dict{Tuple{String,Bool}, Vector{Device}}` per `add_nem_constraints!` call and reuse it for the name list and `contributing_devices`. Use prebuilt name `Set`s for `_key_missing`. |
| B2 | `src/check/nem_constraints.jl:31,46,59,164,40`, `src/check/fcas.jl:239` | High/Medium | `PSY.get_contributing_devices` is called per `GenericConstraint` and per FCAS term (unverified: likely a scan over all devices). `get_component(PSY.Device, ...)` per term. `_type_modeled` is a dynamic `any(t -> device isa t, ...)` over a `Vector{DataType}`. | Cache name to devices per service for the check pass, memoise `any(get_available, devices)` per service, share one name to device `Dict`, cache `typeof(device)` to a modeled `Bool`. |
| B3 | `src/check/fcas.jl:201,243`, `src/fcas/service.jl:70-71` | Medium | `findfirst` over device models per (service, device) pair, and fresh interpolated series names (`"fcas_agc_ramp_rate_$(string(bid_type))"`) with two `has_time_series` calls per device per service. | Memoise `typeof(device)` to model index. Make the series names a `const` tuple per `BidType`. |
| B4 | `src/setters/bids.jl:125,140,141,155,156` | Medium | `set_market_bids!` runs `subset(bids, :DUID => ByRow(==(id)), ...)` per generator, load and storage (twice). That is O(devices times bid rows). `any(==(load_id), bids.DUID)` is a linear scan. Runs in system build, so it counts toward end-to-end time. | One `groupby(bids, [:DUID, :DIRECTION])` with `get(gdf, (id, "GEN"), nothing)`, as `set_fcas_bids!` already does. Use a `Set(bids.DUID)`. |
| B5 | `src/setters/dispatch_limits.jl:~170-176,~240-275`, `src/setters/fcas_scaling.jl:~120-140` | Low/Medium | Per-device `Dict(zip(..., eachrow(...)))` of `DataFrameRow`s (type-unstable field access), per-device `setdiff(full_grid, keys(by_time))`, per-row untyped pushes, and up to 5 and 8 individual `add_time_series!` calls per device with no batching. | Extract typed column vectors per DUID group and index by position. Validate grid alignment once with a `Set`. Check whether bulk time-series update helps in the pinned IS version (unverified). |
| B6 | `replication/pipeline.jl:194-195,260-266,293,302-320` | Low/Medium | `_constraint_violations` is computed twice per `replicate_interval` (`_ramp_violations` calls it again). Each call reads every variable key into DataFrames and iterates `eachrow`. `_violation_direction` does `get_component` per non-zero row. Post-build, but part of interval wall time. | Compute once and derive the ramp frame from it. Cache lookups. Filter to the first timestamp in `read_variable`. |
| B7 | `src/check/nem_constraints.jl:98,156,30,33,50,77,79` | Low | `sort(collect(get_components(GenericConstraint, sys)); ...)`, `unique(DataType[...])` per constraint, and empty `Tuple{Symbol,Union{Nothing,DataType}}[]` allocations per term on the success path. | Shared `const` empty vector or a `nothing` sentinel. |
| B8 | `src/setters/dispatch_limits.jl:16-20`, `src/setters/fcas_scaling.jl:13-14`, `src/constraints/build.jl:205,290`, `replication/inputs.jl:148` | Low | `collect(get_components(...))` appended into `Device[]` (abstractly typed, so later calls dispatch dynamically). `collect(date_range)[1:(end-1)]` copies. `SELECT * ... LIMIT 0` for the schema on every call, per table per interval. | Concrete element types, avoid the copy, cache the schema per table per `db` when replicating many intervals. |
| B9 | `src/network_models/common.jl:483,807-808` | Low | `get_component(Area, sys, name)` per bus row, on a type with about 5 components. | `Dict{String,Area}` built once (clarity more than speed). |

## Cross-references

- Items A1, A8, B1 and B2 share a theme: repeated lookups across many generic constraints and
  services. Fixing the lookups once (name to device `Dict`, service resolution memo) covers all of
  them.
- Items A11 and the `_check_dispatch_envelope` finding are the same pattern at different call
  sites, so fix them together.
- Any change to a dispatch, FCAS, constraint or loss formulation (A5 to A7, A9) needs a check
  against AEMO documentation per the repository's NEM correctness rule.
