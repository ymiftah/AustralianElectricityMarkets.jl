# Anatomy of PowerSimulations.jl

How upstream PowerSimulations.jl (PSI) builds an optimisation model from a PowerSystems `System`,
how it updates that model between repeated solves, what it requires of the `System`, and where
AustralianElectricityMarketsSimulations (AEMSim) departs from it. It is written as the reference for
redesigning the split between system construction (AEM) and model construction (AEMSim).

## Sources and conventions

| Prefix | Source | Revision |
| --- | --- | --- |
| `psi:` | Sienna-Platform/PowerSimulations.jl `src/` | `main` @ `cfcb71b` (2026-11-09, v0.38.5) |
| `is:` | Sienna-Platform/InfrastructureSystems.jl `src/` | `main` @ `787856a` (2026-11-03, v3.6.4) |
| `docs:` | PowerSimulations.jl `docs/src/` | `main` @ `cfcb71b` |
| `fork:` | ymiftah/PowerSimulations.jl `src/` (the rev AEMSim pins) | `81c0259d` |
| `aemsim:` | `AustralianElectricityMarketsSimulations/src/` | `perf/key-types` @ `79162ba` |

Citations are `prefix:path:line`. A `~` marks a line located to within a few lines. Claims marked
**[probe]** were executed against upstream PSI on PowerSystemCaseBuilder's `c_sys5_re` (5-bus,
two daily forecast windows); see [Probe results](#probe-results).

---

## Part A: PSI anatomy

### A1. The life cycle in one picture

```text
DecisionModel(template, sys; kwargs)          construction  (A2)
  Settings, auto_transform_time_series!  ← may MUTATE sys (adds DeterministicSingleTimeSeries)
  OptimizationContainer, template deep-copy, finalize_template!, validate_time_series!
build!(model)  or  build!(Simulation)          build         (A3)
  build_pre_step!   validate_template_impl!  ← drops device models with no available devices
                    init_optimization_container!  ← MUTATES sys: set_units_base_system!(SYSTEM_BASE)
  instantiate_network_model!, handle_initial_conditions!
  build_impl!(container): expressions → Argument stage → Model stage → objective
execute!(Simulation)                           per step      (A6)
  update_model! → update_parameters! (JuMP.fix) → update_initial_conditions!
  solve! → write_results! → advance_execution_count!
  _update_simulation_state! → system state → date_ref += interval
```

### A2. Construction: `DecisionModel(template, sys; kwargs...)`

The chain is the keyword constructor (psi:operation/decision_model.jl:89-141), then `Settings(sys; ...)`
(psi:core/settings.jl:57-124), then the inner constructor (psi:operation/decision_model.jl:56-87).

| Step | Where | Reads from `sys` | Effect |
| --- | --- | --- | --- |
| `Settings(sys)` | psi:core/settings.jl:57-124 | `stores_time_series_in_memory` | forces `time_series_cache_size = 0` (cache off) when series are in memory (:82-85) |
| `auto_transform_time_series!` | psi:operation/decision_model.jl:68 → psi:utils/powersystems_utils.jl:558-587 | series counts, forecast summary | **mutates `sys`**: `transform_single_time_series!(sys, horizon, interval; delete_existing = false)` (:579), only when `horizon` and `interval` are both given, static series exist and that interval is not yet present |
| `get_deterministic_time_series_type` | psi:utils/powersystems_utils.jl:589-606 | `get_time_series_counts_by_type` | returns `Deterministic` or `DeterministicSingleTimeSeries`; errors if neither exists, even for a custom problem |
| `OptimizationContainer(...)` | psi:core/optimization_container.jl:87-128 | base power | empty JuMP model; rejects an external JuMP model with direct mode (:97-103) |
| `_copy_template_for_build` | psi:operation/problem_template.jl:361-383 | none | deep-copies the template, so edits to the caller's template after this point are invisible to the model |
| `finalize_template!` | psi:operation/problem_template.jl:385-390 | contributing-device mapping, available components | expands aggregated service models per service name (:321-350), fills `contributing_devices_map`, attaches services to device models |
| `validate_time_series!` | psi:operation/decision_model.jl:259-315 | resolutions, intervals, forecast horizon | sets resolution, interval and horizon in settings |

`DecisionModel` does not copy the `System`. `model.sys` is the caller's object, and every later
mutation lands on it (psi:operation/decision_model.jl:56-87).

### A3. Build: `build!(model)` and the stage order

`build!` (psi:operation/decision_model.jl:365-402) calls `build_impl!(model)` (:340-349) inside a
`try/catch`. **Any exception is logged and turned into status `FAILED` without being rethrown**
(:391-395). `build!(::Simulation)` does rethrow (psi:simulation/simulation.jl:718-722).

`build_impl!(model)` runs:

1. **`build_pre_step!`** (psi:operation/decision_model.jl:317-338):
   - `validate_template` → `validate_template_impl!` (psi:operation/template_validation.jl:174-247). It
     builds a device cache per model (`get_available` ∧ `filter_function`, psi:operation/decision_model.jl:655-667)
     and **deletes device and branch models with no available components** (psi:operation/template_validation.jl:195-206, 220-235).
   - `init_optimization_container!` (psi:core/optimization_container.jl:315-368):
     - **`set_units_base_system!(sys, "SYSTEM_BASE")`** (:320), never restored. **[probe]**
     - initial time from `get_forecast_initial_timestamp` (:324-331)
     - `horizon_count = horizon ÷ resolution`, which floors silently (:337)
     - `_finalize_jump_model!` (:275-313), covering the optimizer, direct mode, warm start and `store_variable_names`
   - `init_model_store_params!` (psi:operation/decision_model.jl:232-257) sets interval, horizon count,
     resolution and base power.
2. **`instantiate_network_model!`** (psi:operation/operation_model_interface.jl:361-373; psi:core/network_model.jl:548-630).
   It builds the Ybus, network reductions and subnetworks, and only reads `sys`.
3. **`handle_initial_conditions!`** (psi:operation/decision_model.jl:569-621); see [A9](#a9-initial-conditions).
4. **`build_model!`** → `build_impl!(container, template, sys)` (psi:core/optimization_container.jl:697-833):

| # | Stage | Lines |
| --- | --- | --- |
| 1 | `initialize_system_expressions!`: `ActivePowerBalance` containers per network model | 706-712 |
| 2 | `initialize_hvdc_system!` | 714-719 |
| 3 | `construct_device!(…, ArgumentConstructStage(), …)` for `template.devices` | 722-736 |
| 4 | `construct_services!(ArgumentConstructStage)`; `GroupReserve` last; services without contributing devices skipped | 738-747; psi:services_models/services_constructor.jl:15-54 |
| 5 | `construct_device!(ArgumentConstructStage)` for `template.branches` | 749-763 |
| 6 | `construct_device!(ModelConstructStage)` for devices | 764-778 |
| 7 | `construct_network!` + `construct_hvdc_network!` | 781-788 |
| 8 | `construct_device!(ModelConstructStage)` for branches | 789-803 |
| 9 | `construct_services!(ModelConstructStage)` | 805-814 |
| 10 | `update_objective_function!`: one `@objective` from invariant and variant terms | 816-819, 835-842 |
| 11 | `add_power_flow_data!`, `check_optimization_container` | 823-831 |

Device and service order is the template `Dict`'s iteration order (psi:operation/problem_template.jl:2),
not insertion order.

**What each stage creates.** The stock renewable constructor is the reference
(psi:devices_models/device_constructors/renewablegeneration_constructor.jl:1-116):

- **ArgumentConstructStage**:
  - `add_variables!`
  - `add_parameters!(ActivePowerTimeSeriesParameter)`, gated by
    `haskey(get_time_series_names(model), P)` (:15-20)
  - market-bid parameters, `add_cost_expressions!`
  - `add_to_expression!` into the balance and range expressions
  - `add_feedforward_arguments!`, `add_event_arguments!`
- **ModelConstructStage**:
  - `add_constraints!`, `add_feedforward_constraints!`
  - `objective_function!`
  - `add_event_constraints!`, `add_constraint_dual!`

The rule is that arguments (variables, parameters, expressions) of every component exist before any
constraint is written. A service constructor can therefore add reserve variables into a device's
range expression before the device writes its limit constraint. `RangeReserve` follows the same split
(psi:services_models/services_constructor.jl:96-152).

Constructors re-query the system at every stage through `get_available_components(model, sys)`
(psi:utils/powersystems_utils.jl:18-39), not through the device cache.

### A4. How time series become parameters

**Hierarchy.** The roots are in IS (is:Optimization/optimization_container_types.jl:7, 24-27):
`ParameterType`, `RightHandSideParameter`, `ObjectiveFunctionParameter`,
`TimeSeriesParameter <: RightHandSideParameter`. PSI adds (psi:core/parameters.jl):

| Family | Types (line) |
| --- | --- |
| `TimeSeriesParameter` | `ActivePower` 444, `ReactivePower` 449, `ActivePowerOut` 454, `ActivePowerIn` 459, `ShiftUp`/`ShiftDown` 464/469, `Requirement` 474, `FromTo`/`ToFromFlowLimit` 496/501, `Max`/`MinInterfaceFlowLimit` 506/511, branch ratings 479-490, PWL breakpoints 570-577 |
| `VariableValueParameter <: RightHandSideParameter` (513) | `UpperBoundValue` 518, `LowerBoundValue` 523, `OnStatus` 528, `FixValue` 533 |
| `ObjectiveFunctionParameter` | `CostFunction` 538, `FuelCost` 543, `StartupCost` 546, `ShutdownCost` 549, `CostAtMin` 552-558, `PiecewiseLinearSlope` 561-567 |
| `EventParameter` (582) | `AvailableStatus` 587, `ActivePowerOffset` 592, `ReactivePowerOffset` 597, countdown 602 |

Upstream has **no** parameter family that edits constraint coefficients or objective coefficients
from a time series. `ConstraintCoefficientParameter` and `TimeSeriesCostParameter` exist only in the
fork; see [Appendix: fork delta](#appendix-fork-delta).

**Naming.**

- `DeviceModel.time_series_names::Dict{Type{<:ParameterType},String}` (psi:core/device_model.jl:63)
  defaults to `get_default_time_series_names(D, B)` (:75).
- A user-supplied `time_series_names` **replaces** the whole default dict, while `attributes`
  **merges** into `get_default_attributes` (:75 vs :79-82; psi:core/service_model.jl:57 vs 61-64).
- Neither default has a generic fallback.
- The aggregated-service expansion drops user `time_series_names` and feedforwards
  (psi:operation/problem_template.jl:335-342).

**The build-time read** (psi:parameters/add_parameters.jl:378-506):

1. `ts_name = get_time_series_names(model)[T]`, a `KeyError` if absent (:509-510).
2. Devices without the series are **skipped silently** (`!PSY.has_time_series`, :406-409). If no device has
   it, an `@info` is logged and no container is created (:455-458).
3. Each unique series UUID is read **once**: one window from `initial_time`, `len = horizon count`,
   `ignore_scaling_factors = true` (`get_time_series_initial_values!`,
   psi:core/optimization_container.jl:2054-2081).
4. The **parameter array** is indexed by series UUID × time step. The **multiplier array** is indexed by
   device name × time step, NaN-filled and then set from `get_multiplier_value(T(), device, formulation)`
   (psi:parameters/add_parameters.jl:462-504; psi:core/optimization_container.jl:1296-1307).
5. `check_optimization_container` errors only if **every** multiplier is NaN
   (psi:core/optimization_container.jl:381-397).

Services read the series without a `has_time_series` guard, so a missing series throws
(psi:parameters/add_parameters.jl:855-917, :870). The service parameter key's `meta` is the service
name (:890).

`get_multiplier_value` has no generic default (psi:devices_models/devices/default_interface_methods.jl:21-24).
The stock methods return per-unit component values, for example `get_max_active_power` for
renewables (psi:devices_models/devices/renewable_generation.jl:19-20) and `get_requirement` for
reserves (psi:services_models/reserves.jl:40-41). That is why the build forces `SYSTEM_BASE`.

**Parameter element type, the most important switch in PSI.** The parameter array holds
`JuMP.VariableRef` only when `built_for_recurrent_solves(container) && !rebuild_model`. Otherwise it
holds `Float64`, and the value is **baked into the constraints as a constant**
(psi:core/optimization_container.jl:1260-1264, 1285-1289, 1322-1326).

- The flag defaults to false (:123).
- It is set only by `_build_single_model_for_simulation` (psi:simulation/simulation.jl:325) and by
  `EmulationModel` (psi:operation/emulation_model.jl:277).
- Cost parameters and `FixValueParameter` are always `Float64` (psi:core/optimization_container.jl:1359-1390, 1505-1528).
- **[probe]**: a standalone `build!` gives `Float64` and a `Simulation` build gives `VariableRef`.

### A5. Container keys, `meta`, and compile cost

- `VariableKey`, `ConstraintKey`, `AuxVarKey`, `ParameterKey`, `InitialConditionKey` and
  `ExpressionKey` are each `{T<:EntryType, U<:InfrastructureSystemsType}` with a single field
  `meta::String` (is:Optimization/optimization_container_keys.jl:15-43). An abstract `U` is rejected
  except for constraints (:53-56).
- The `meta::String` constructor (:71-78) is more specific than the checking one (:61-69). Every normal
  construction, including `meta = ""`, therefore skips `check_meta_chars`, so a `"__"` in a meta is
  never rejected even though it breaks the encoded name (`T__U__meta`, :95-118).
- Stock uses of `meta`: `"ub"`/`"lb"` on range constraints, the service name on service variables and
  parameters, and the variable type name on `FixValueParameter`.
- Containers are `OrderedDict{<:Key, AbstractArray}` (psi:core/optimization_container.jl:63-85), so each
  lookup is one dynamic dispatch. That is cheap at run time.
- The **compile** cost comes from specialisation. `add_variable!`, `add_constraints!`, `add_to_expression!`,
  `_add_parameters!`, `add_param_container!`, the `get_variable_*` and `get_multiplier_value` traits,
  and `construct_device!`/`construct_service!` are each compiled per (key type, component type,
  formulation). PSI marks its hot spots with `# PERF: compilation hotspot`
  (psi:core/optimization_container.jl:1013; psi:devices_models/devices/common/add_variable.jl:41;
  psi:parameters/add_parameters.jl:377, 769; psi:devices_models/devices/common/range_constraint.jl:938).
- ADR 0100 measured a 1.0 to 1.4 s first-use compile cost per key type, of which about 0.78 s is
  inference saved for each key type removed.

### A6. Repeated solves: `Simulation`

**Build** (`build!(sim)` → `_build!`, psi:simulation/simulation.jl:556-642):

1. Check initial times and executions per model (:577-602).
2. Optionally spawn system JSON serialisation on a thread (:604-608). It runs **only if
   `store_systems_in_results`**. Its comment says systems are read-only during build, which is false
   because `init_optimization_container!` switches the units base.
3. Build each model with `_build_single_model_for_simulation` (:312-336), which sets the initial time
   and **`built_for_recurrent_solves = true`** before `build_impl!`.
4. Initialise the simulation state and the HDF5 store.

**Execute** (`execute!` → `_execute!`, psi:simulation/simulation.jl:939-~1100; `execute!` at 1114). For each step and each
model in execution order:

1. `set_current_time!(sim, date_ref[model])`.
2. Unless this is the very first execution, `update_model!(model, sim)` (:928-937), which calls:
   - `update_parameters!(model, state)` (psi:operation/operation_model_simulation_interface.jl:17-31):
     - `cost_function_unsynch`, which zeroes the objective's variant terms when it has any
       (psi:core/optimization_container.jl:137-144);
     - `update_parameter_values!(model, key, state)` for every parameter key;
     - then, if the objective was unsynchronised, a full `@objective` re-set.
   - `update_initial_conditions!(model, state, InterProblemChronology())`.
   - Only under `rebuild_model`: `reset_optimization_model!` + `build_impl!`.
3. `solve!(step, model, current_time, store)` (psi:operation/decision_model.jl:549-567) runs
   `solve_impl!` and asserts the current time. On `SUCCESSFULLY_FINALIZED` only, it then runs
   `write_results!` and `advance_execution_count!`.
4. `_update_simulation_state!` (psi:simulation/simulation.jl:831-889) reads every stored key back from the
   HDF5 store into the decision state.
5. For the last model: `_update_system_state!`, `_write_state_to_store!`, then events.
6. `date_ref[model] += interval`, and the warm start if enabled.

**[probe]** order observed on a 2-step simulation:

```text
solve_impl! t=2024-01-01T00:00:00 units=SYSTEM_BASE
update_parameter_values! ActivePowerTimeSeriesParameter PowerLoad t=2024-01-02T00:00:00
update_parameter_values! ActivePowerTimeSeriesParameter RenewableDispatch t=2024-01-02T00:00:00
update_initial_conditions! t=2024-01-02T00:00:00
solve_impl! t=2024-01-02T00:00:00 units=SYSTEM_BASE
```

The first solve uses the build-time values. Every later solve is preceded by a parameter sweep over
**all** keys, then the initial conditions.

### A7. How each parameter family is updated

The dispatch chain:

1. `update_parameter_values!(model, key::ParameterKey{T,U}, state)` (psi:parameters/update_parameters.jl:4-22)
2. `update_container_parameter_values!(container, model, key, ::DatasetContainer{InMemoryDataset})`
   (psi:parameters/update_container_parameter_values.jl:675-839)
3. `_update_parameter_values!(array, ::T, attributes, ::Type{U}, model, state)`

| Family | Method | How the model changes |
| --- | --- | --- |
| Time series, device (`TimeSeriesAttributes{<:AbstractDeterministic}`) | psi:parameters/update_container_parameter_values.jl:45-108 | new window via `get_time_series_values!`, then `JuMP.fix(param, v; force = true)` |
| Time series, reduced branches / services | :111-177 / :179-218 | same |
| Time series, `EmulationModel` (`SingleTimeSeries`) | :220-291 | one value per step |
| `UpperBound` / `LowerBound` / `OnStatus` (feedforward) | :293-450 (Emulation 452-564) | copied from the decision state, then `fix`; `OnVariable` rounded and range-checked |
| `FixValueParameter` | psi:parameters/update_parameters.jl:24-56 | `JuMP.fix(variable, param)` on each affected **decision variable** |
| `ObjectiveFunctionParameter` (`OfferCurveCost` / `MarketBidCost` time-variant fields) | psi:parameters/update_cost_parameters.jl:1-73 (rebuild 280-405) | `Float64` array updated; a **new `AffExpr` per component and time step**; `ProductionCostExpression` overwritten; full `@objective` re-set |
| `EventParameter` | psi:parameters/update_container_parameter_values.jl:578-670 | `fix` |

**Invariants across all families:**

- **Parameters are fixed JuMP variables.** They are created by `add_jump_parameter` (`@variable` plus
  `fix`, psi:utils/jump_utils.jl:9-14) and updated with `JuMP.fix(...; force = true)`
  (psi:core/parameters.jl:408-416, 429-439). PSI uses neither `MOI.Parameter` nor ParameterJuMP; they appear
  only in comments (psi:utils/jump_utils.jl:9; psi:simulation/simulation.jl:323).
- **Constraints are never edited.** No upstream code calls `set_normalized_coefficient`,
  `set_normalized_rhs` or `set_objective_coefficient`. A time-varying bound or right-hand side is
  `parameter × multiplier` with the parameter re-fixed.
- **Multipliers are frozen at build.** No update path writes the multiplier array. The docs say the
  same: "the multiplier is fixed at build time" (docs:explanation/branch_rating_limits.md:146-147).
  A change to a rating or scaling factor after build is silently ignored.
- **DecisionModel time-series and feedforward updates check every written value for finiteness**
  (psi:parameters/update_container_parameter_values.jl:98-101 and similar). The EmulationModel
  variable-value and event updates (:452-482, :635-670) and the `FixValueParameter` re-fix
  (psi:parameters/update_parameters.jl:26-55) do not. The build path has no such check.
- **Constraints are rebuilt only under `rebuild_model`** (psi:simulation/simulation.jl:930-934). In that
  mode parameters become `Float64` and the model is rebuilt each step.
- **Components made unavailable after build are skipped** in the update, leaving stale values
  (`get_available_components` per step, psi:utils/powersystems_utils.jl:18-39).

### A8. The time-series cache

- `get_time_series_values!(T, model, component, name, initial_time, horizon; interval)`
  (psi:operation/time_series_interface.jl:1-47).
- With the cache on, it is keyed by `TimeSeriesCacheKey(uuid, T, name, resolution, interval)`
  (is:time_series_cache.jl:146-152) and built by `make_time_series_cache` as a `ForecastCache`
  (is:time_series_cache.jl:488-540).
- **The cache reads forward only.** It accepts the last-read or next timestamp and throws
  `InvalidValue` otherwise (`_check_timestamp`, is:time_series_cache.jl:~63-79). **[probe]**:
  re-reading window 1 after window 2 gives
  `InvalidValue("Invalid request. Valid timestamps are [2024-01-02T00:00:00].")`.
- `time_series_cache_size` is only an on/off switch (`use_time_series_cache`, psi:core/settings.jl:161).
  It is never passed to IS, which therefore uses its 1 MiB default (is:time_series_cache.jl:1).
- **The cache is turned off when the System stores time series in memory**
  (psi:core/settings.jl:82-85). Every step then does an uncached `IS.get_time_series_values`
  (psi:operation/time_series_interface.jl:14-24). AEM builds replay systems with
  `time_series_in_memory = true` (`src/system/nemde.jl:57`), so this is the path AEMSim runs on.
- Per-step allocations per key: one `Set{String}`, one value vector per unique series, and one
  `_unwrap_for_param` per value (psi:parameters/update_container_parameter_values.jl:77-103).

### A9. Initial conditions

- At build, `handle_initial_conditions!` (psi:operation/decision_model.jl:569-621) builds an
  initialisation model only if some device formulation has `requires_initialization(formulation()) == true`
  (psi:operation/operation_model_interface.jl:177-194).
- That model is a deep copy with a 3-step horizon (psi:initial_conditions/initialization.jl:79-115). It
  calls `get_initial_conditions_device_model` / `get_initial_conditions_service_model` for **every**
  model, and the service one has **no fallback** (psi:initial_conditions/initialization.jl:48).
- `add_initial_condition!` creates the IC vectors (psi:initial_conditions/add_initial_condition.jl:210-262):
  - `InitialCondition{T, VariableRef}` for a recurrent build, otherwise `Float64`;
  - values come from the initialisation solve or from `initial_condition_default`, read from the
    System (for thermal: `get_active_power`, `get_status`, `get_time_at_status`).
- Per step, `InterProblemChronology` loops the IC keys into `update_initial_conditions!`
  (psi:simulation/initial_condition_update_simulation.jl:1-69):
  - values come from the **system state**, i.e. the previous solve's results;
  - they are written with `set_ic_quantity!` → `JuMP.fix` (psi:initial_conditions/calculate_initial_condition.jl);
  - a `Float64` IC is never pushed to the model;
  - the update is skipped while `execution_count < 1` (psi:initial_conditions/update_initial_conditions.jl:1-26);
  - `DevicePower` is checked against limits (psi:simulation/initial_condition_update_simulation.jl:91-146).
- `IntraProblemChronology` raises `"Not Implemented yet"` (:12-22), although the docs describe it
  (docs:explanation/chronologies.md:3-7).

**PSI's native mechanism for "state carried from the previous solve" is the initial condition, fed
from the system state.** A time-series parameter is the mechanism for exogenous per-step inputs.

### A10. Stepping a `DecisionModel` without a `Simulation`

Upstream has **no supported API**, and no upstream test steps a `DecisionModel` by hand.

`solve!(model)` (psi:operation/decision_model.jl:462-533):

- on every call, re-initialises the result store (psi:operation/decision_model_store.jl:25-60), runs the
  numerical-bounds check, serialises the model by default, and writes results at `initial_time`;
- never advances the execution count.

`get_current_time = initial_time + interval × execution_count` (psi:operation/decision_model.jl:225-230).

The internal recipe, which runs **[probe]**:

```julia
PSI.get_optimization_container(model).built_for_recurrent_solves = true
build!(model; output_dir)
PSI.solve_impl!(model)                       # step 1, build-time values
for step in 2:n
    PSI.advance_execution_count!(model)
    PSI.update_parameters!(model, PSI.SimulationState())   # time-series families only
    PSI.solve_impl!(model)
end
```

On `c_sys5_re` the renewable parameter went from 0.9852 to 1.0676 and the objective from 172276.84 to
184778.53 between the two windows.

Feedforward and `VariableValue` parameters need a populated decision state, and initial conditions
need a system state. Both are what `Simulation` provides. EmulationModel's `run!`
(psi:operation/emulation_model.jl:511-572, with `run_impl!` at 454-485) is the supported single-period stepping loop, with
interval equal to resolution, `SingleTimeSeries` inputs, and initial conditions from its own store.

### A11. Extension surface for an external package

Almost none of this is exported. An extension does `import PowerSimulations as PSI` and extends
`PSI.name` (psi:PowerSimulations.jl:1-574).

**Custom device formulation (`<: PSI.AbstractDeviceFormulation`):**

| Method | Without it |
| --- | --- |
| `construct_device!(container, sys, ::ArgumentConstructStage / ::ModelConstructStage, ::DeviceModel{D,B}, ::NetworkModel)` | MethodError |
| `get_default_time_series_names(::Type{D}, ::Type{B})`, `get_default_attributes` | MethodError inside the `DeviceModel` constructor |
| `get_variable_binary(var, ::Type{D}, ::B)` | error (psi:devices_models/devices/default_interface_methods.jl:4-5) |
| `get_variable_upper_bound` / `lower_bound` / `warm_start_value` | `nothing` (:7-11) |
| `get_multiplier_value(param, d, ::B)` | error (:21-24) |
| `requires_initialization(::B)` | `false` |
| `get_initial_conditions_device_model` | error, only once initialisation runs (:29-33) |

**Custom service formulation (`<: PSI.AbstractServiceFormulation`):** `construct_service!` for both
stages, the two defaults above, the 4-argument variable bounds, plus two methods with **no fallback**:

- `_modify_device_model!(devices_template, ::ServiceModel{S,B}, contributing_devices)`, which is called by
  `finalize_template!` at construction for every service with contributing devices
  (psi:operation/problem_template.jl:265-313);
- `get_initial_conditions_service_model`.

**Custom `DecisionProblem`.** The docs say only `build_model!` is mandatory
(docs:how_to/adding_new_problem_model.md:56-67). In the code, a non-default problem also hits:

- `validate_time_series!` (defined only for `DefaultDecisionProblem`, psi:operation/decision_model.jl:259);
- `validate_template` (generic method throws, :215-217);
- `reset!` (Default-only, :413).

Subtyping `DefaultDecisionProblem` avoids all three, and AEMSim does this
(`NEMDispatchProblem <: DefaultDecisionProblem`).

**Where per-step logic hooks in,** from coarsest to finest:

- `update_model!(model, sim)` (psi:simulation/simulation.jl:928);
- `update_parameters!(::DecisionModel, ::SimulationState)`;
- `update_parameter_values!(model, ::ParameterKey{MyParam,U}, state)`;
- `update_container_parameter_values!(container, model, key, input)`;
- `_update_parameter_values!(array, ::MyParam, ::TimeSeriesAttributes{U}, ::Type{V}, ::DecisionModel, input)`
  (psi:parameters/update_container_parameter_values.jl:44-62).

A **new parameter type** that only needs a new window each step needs no update method at all:
subtype `TimeSeriesParameter` and define `get_multiplier_value`. Such a type already writes its values to the store and state,
because it inherits `should_write_resulting_value(::Type{<:RightHandSideParameter}) = true`
(psi:core/parameters.jl:604). Other `ParameterType`s default to `false`
(is:Optimization/optimization_container_types.jl:22) and need their own method.

**Signature trap:** several helpers accept only `IS.FlattenIteratorWrapper`, not `Vector`. These include
`_make_device_cache` (psi:operation/decision_model.jl:625, 641), the range-constraint helpers
(psi:devices_models/devices/common/range_constraint.jl:45-84) and `add_variable_cost!`. The event
`add_parameters!` accepts only `Vector`.

### A12. Every place PSI touches the `System`

| What | Where | When |
| --- | --- | --- |
| `transform_single_time_series!(sys, horizon, interval; delete_existing = false)` | psi:utils/powersystems_utils.jl:579 | construction, conditional (A2) |
| `set_units_base_system!(sys, "SYSTEM_BASE")`, never restored | psi:core/optimization_container.jl:320 | every build, plus the initialisation model (psi:initial_conditions/initialization.jl:97) **[probe]** |
| `PSY.to_json` on a spawned thread, concurrently with model builds | psi:simulation/simulation.jl:604-608, 1175-1194 | `Simulation` build when `store_systems_in_results` (default `true`); races with the units switch above |
| `PSY.check_component` | psi:operation/decision_model.jl:632 | build when `check_components` (may throw) |
| results system units | psi:simulation/simulation_results.jl:277-279 | results only |

PSI does not call `PSY.set_*!` on components anywhere in the build or update path.

Files PSI writes:

- the output directory, the log file and the container metadata (psi:core/optimization_container.jl:974-995);
- `initial_conditions.bin` (psi:operation/operation_model_interface.jl:223-225);
- on solve, model exports and `infeasible_*.json`;
- `jump_model.json` from standalone `solve!` unless disabled.

### A13. Best practices and gotchas

Best practices, as upstream code and docs imply them:

1. **Give the System its forecasts before construction.** Either call
   `transform_single_time_series!(sys, horizon, interval)` yourself (docs:tutorials/pcm_simulation.jl,
   Sequencing section) or pass both `horizon` and `interval` and let PSI do it.
2. **Rolling horizon means `Simulation`.** That is the only route that makes parameters updatable
   (`built_for_recurrent_solves`, A4). The docs describe rolling horizons only through
   `SimulationSequence` (docs:explanation/sequencing.md; docs:tutorials/pcm_simulation.jl, Sequencing
   section).
3. **Exogenous per-step inputs are time-series parameters.** If the per-step value is "the next window of
   the series", no custom update code is needed. Values that change per step but are not a stored
   series have no upstream route except a custom update method.
4. **State carried between solves is an initial condition**, updated from the system state by the
   chronology. A feedforward carries a value from one model to another.
5. **Put scale in the multiplier and shape in the series**, and accept that the multiplier is frozen.
6. **Register every JuMP object in the container**, using anonymous JuMP variables and constraints
   (docs:how_to/adding_new_problem_model.md:21-23; docs:how_to/register_variable.md:6).
7. **Subtype `DefaultDecisionProblem`** unless you are ready to implement the validation and reset hooks.

Gotchas, each verified in code:

| # | Gotcha | Where |
| --- | --- | --- |
| 1 | `build!(::DecisionModel)` swallows exceptions and returns `FAILED`; the cause is only in the log | psi:operation/decision_model.jl:391-395 |
| 2 | The template is deep-copied at construction; the System is not copied | psi:operation/problem_template.jl:361-383 |
| 3 | The units base is switched to `SYSTEM_BASE` on every build and never restored | psi:core/optimization_container.jl:320 **[probe]** |
| 4 | Standalone parameters are `Float64` constants, so updates never reach the solver | psi:core/optimization_container.jl:1285-1326 **[probe]** |
| 5 | Multipliers are frozen at build | A7 |
| 6 | The forecast cache reads forward only, and is off when series are in memory | A8 **[probe]** |
| 7 | `validate_time_series!` silently overwrites a user `resolution` when the System has exactly one | psi:operation/decision_model.jl:278-279 |
| 8 | The mixed-forecast check `Set([...]) ∈ existing_types` is always false, so a mixed System silently uses `Deterministic` | psi:utils/powersystems_utils.jl:592 **[probe]** |
| 9 | The abstract-type error message interpolates undefined `$V` and raises `UndefVarError` instead | psi:core/optimization_container.jl:94 **[probe]** |
| 10 | Horizon is floored by integer division; the `@assert` that it is positive can be compiled out | psi:core/optimization_container.jl:337-338 |
| 11 | `time_series_names` replaces the defaults, and `attributes` merges | psi:core/device_model.jl:75-82 |
| 12 | Device series missing: device silently skipped. Service series missing: throw | psi:parameters/add_parameters.jl:406-409, 870 |
| 13 | Device models with no available devices are deleted from the copied template | psi:operation/template_validation.jl:195-235 |
| 14 | If the System has no services, all service models are emptied | psi:operation/problem_template.jl:229-234 |
| 15 | A key's `meta` is never checked for `"__"` | is:Optimization/optimization_container_keys.jl:71-78 |
| 16 | The whole objective is re-set every step once variant cost terms exist; cost updates allocate | A7 |
| 17 | `FixValueParameter` update re-fixes to `param`, not `param × multiplier` (latent: every stock multiplier is 1.0) | psi:parameters/update_parameters.jl:46-50 vs psi:feedforward/feedforward_constraints.jl:516 |
| 18 | `store_variable_names` is forced on whenever debug logging is enabled | psi:core/optimization_container.jl:302-304 |
| 19 | The `isnothing(sim_info)` guard in `get_rebuild_model` is dead code | psi:operation/operation_model_interface.jl:26-32 |
| 20 | `check_simulation_chronology`'s error message interpolates an undefined `interval` | psi:simulation/simulation_sequence.jl:10-11 |
| 21 | Standalone `solve!` serialises and reallocates on every call | A10 |

---

## Part B: AEMSim against PSI

### B1. How AEMSim builds and steps

`scripts/replay_batch_worker.jl` does, per chunk:

1. `template_nemde()` (aemsim:templates/template_nemde.jl:18-37), which takes no data.
2. AEM's `nem_system(...)` builds a fresh System.
3. **`prepare_replay!(sys, template, steps)`** (aemsim:checks/replay_range.jl:47-61), the only place
   in production that writes to the System. One of the four `with_units_base` toggles
   (aemsim:offers/state_updates/fcas.jl:44) is on the per-step custom branch, which production does
   not reach.
4. `DecisionModel(NEMDispatchProblem, template, sys; …)` (aemsim:problems/nem_dispatch.jl:28-39).
5. A one-model `Simulation` with `InterProblemChronology`.
6. `build!(sim; store_systems_in_results = false)`, then `execute!`.

This is the supported PSI shape (A6). Parameters are `VariableRef`, and the threaded JSON race (A12)
is avoided by `store_systems_in_results = false`.

### B2. The System writes and their PSI counterparts

All writes except the custom-branch toggle at aemsim:offers/state_updates/fcas.jl:44 happen before
`build!` and are reached from `prepare_replay!`. None happens per step in production.

| # | AEMSim write | Why it exists | PSI-native home (candidate) |
| --- | --- | --- | --- |
| 1 | `_prepare_replay_forecasts!`: `transform_single_time_series!` (aemsim:checks/replay_range.jl:13-22) | PSI needs forecasts | AEM at `nem_system` time, or PSI's own `auto_transform_time_series!` (A2). Both are upstream-sanctioned. |
| 2 | `energy_offer[_decremental]`: loss-factor referred, rounded to cents (aemsim:offers/effective_offers.jl:334-352) | the stock band-price parameter cannot divide and round at read time | AEM-written series (a data derivation from bids and MLF) |
| 3 | MNSP fixed-load value/invoked, with DSTS removal (:273-293) | NaN → value + flag | AEM-written series |
| 4 | `ramp_up_rate` / `ramp_down_rate`: min(bid, telemetry), composite for storage (:440-489) | depends on observed `initial_mw` for storage | AEM series for the state-independent part; the state-dependent part is a state question (B4) |
| 5 | `fcas_agc_ramp_rate_<svc>` (:495-514) | regulation ramp | AEM-written series |
| 6 | `initial_mw_seed`, `fixed_load_seed`, `fixed_load_invoked_seed` (:75-109) | the first solve has no previous state | **initial conditions** (A9) under simulated state; an AEM observed-state series under replay |
| 7 | `fcas_effective_<BT>` (`NTuple{15}`) and `fcas_ramping_limits_<BT>` (`NTuple{2}`) (aemsim:offers/fcas_effective.jl:567-611) | FCAS trapezium scaling, enablement and ramping with observed state | AEM series for observed state; state-dependent under simulated state (B4) |
| 8 | tie-break scales + remove and re-add the `EnergyTieBreak` service (aemsim:offers/tie_break.jl:149-179) | tied-band scale and service membership | AEM builds the service and its series once |
| 9 | `loss_demand_coefficient` on `AreaInterchange` (aemsim:offers/loss_demand.jl:42-62) | demand term of the loss factor | AEM-written series |
| 10 | `NEMDispatchInputs` supplemental attribute (aemsim:offers/effective_offers.jl:124-133) | records which series key feeds which parameter | disappears if AEM writes fixed series names that the formulations' `get_default_time_series_names` declare |
| 11-13 | `exclude_unmodeled_services!`: `set_available!(false)` on excluded `GenericConstraint`s and their rollback, plus the exclusion record in `ext` (aemsim:templates/template_nemde.jl:99-169) | "not in this replay" | **template scope**: a per-name `ServiceModel`, or a device-model `filter_function` attribute (psi:operation/decision_model.jl:655-667). PSI already expands aggregated service models per name (A2) and drops empty models (A3). |
| 14 | `with_units_base(sys, "SYSTEM_BASE")` toggles (four sites) | read per-unit values | unnecessary inside PSI, which forces `SYSTEM_BASE` anyway (A12) |

Writes 2-9 are **data derivations from AEM's own inputs** (bids, telemetry, MLFs, observed state). In
PSI's model they are the System's time series: written once, before construction, by whoever builds
the System. Writes 11-13 are **scope**, which PSI expresses through the template. None of them
needs AEMSim to own the System.

### B3. The per-step path

- AEMSim overrides `update_container_parameter_values!` for 10 parameter types
  (aemsim:offers/state_updates.jl, aemsim:offers/state_updates/{energy,fcas,mnsp}.jl).
- Under `ObservedState`, the only source `_state_source()` returns (aemsim:types/state.jl:123-125), every
  override `invoke`s the stock method through `_stock_state_update!` (aemsim:psi_compat.jl:167-197). The
  per-step update is then PSI's time-series update of A7, reading the series B2 wrote.
- The custom branch is unreachable in production. It runs only under `SimulatedState`, which throws
  (aemsim:types/state.jl:117-119), or under the test switch `_FORCE_CUSTOM_STATE_UPDATES`.
- That branch holds the typing defects:
  - `_step_cache` infers as `Any` from `PSI.get_ext(model)::Dict{String,Any}` (aemsim:offers/state_updates.jl:34-55);
  - closures passed as `::Function`;
  - runtime `Val` and `Symbol(...)` dispatch;
  - `PSY.get_component` by name per device per step;
  - one-element series reads;
  - direct writes with the private `_set_param_value_at!` and `_apply_coefficient_targets!`.
- What production does pay for per step:
  - the 10 override shims and their global-flag reads;
  - PSI's uncached series reads, because the System stores series in memory (A8);
  - PSI's whole-objective re-set, because the fork's cost targets make the objective variant (A7).

### B4. Where AEMSim's design and PSI's design disagree

1. **State-dependent inputs.**
   - PSI carries solve-to-solve state through **initial conditions** fed from the system state (A9).
   - AEMSim instead derives state-dependent inputs (storage composite ramps, FCAS trapezium
     enablement, fixed-load invoked flags, seeds) from the observed `NEMUnitState` and writes them as
     series (ADR 0098). Its simulated-state plan replaces those series with custom parameter updates
     (ADR 0096).
   - Upstream has no mechanism for "parameter value = f(previous solve)" except initial conditions and
     feedforwards.
2. **Coefficient and cost updates.**
   - The tie-break, loss-demand and FCAS-slope parameters edit constraint coefficients, and the
     energy, MNSP, FCAS and slack band prices edit objective coefficients. Both use fork-only machinery
     (Appendix).
   - Upstream would express a time-varying price as an `ObjectiveFunctionParameter` on
     `MarketBidCost`/`OfferCurveCost`, at the cost of a fresh `AffExpr` per step (A7). A time-varying
     coefficient has no upstream route; it would have to become a parameter-times-variable product.
3. **Private-API coupling.** `aemsim:psi_compat.jl` overrides or calls these PSI internals:
   - `_modify_device_model!` (no-op for NEM services), required because it has no fallback (A11);
   - `get_initial_conditions_service_model`, likewise;
   - 10 `_unwrap_for_param` methods (aemsim:psi_compat.jl:49-108; upstream hook, so tuple- and curve-valued series work on stock PSI);
   - `_get_time_series_name` for storage;
   - `_set_param_value_at!`, `_apply_coefficient_targets!`;
   - `invoke` of the abstract `update_container_parameter_values!` methods.
4. **ADR 0095 contradicts itself.** It says "AEM processes all data, AEMSim reads only the System"
   (docs/adr/0095-typed-nem-system.md:25) and also that derived inputs "are written by AEMSim, not AEM"
   (:59). It also says no later stage replaces a series (:96), while `set_effective_offers!` uses
   `replace_single_series!` throughout.

### B5. Open questions for the redesign

These are stated, not answered. Each one changes what gets built.

1. **Who owns the derived series (B2, writes 2-9)?** If AEM writes them in `nem_system`, AEMSim
   never writes to the System. What is left in AEMSim is the formulations declaring series names via
   `get_default_time_series_names`, and pre-flight checks that only read.
2. **How is simulated state carried?** Either through PSI initial conditions, with per-step
   recomputation of state-dependent parameters from the IC values in a custom
   `_update_parameter_values!`, or by keeping replay on observed-state series only and dropping
   `SimulatedState`.
3. **Do we keep the fork's coefficient and cost targets** (and upstream them), or reformulate onto
   upstream mechanisms? AEMSim depends on them at about 15 sites (Appendix).
4. **Scope as template.** Should exclusions become per-name service models or `filter_function`
   attributes, so that `available` stays the System's own data?
5. **Per-step cost budget.** With the cache off and the objective re-set every step, is the update
   path measured against the 0.24 s per interval in ADR 0098? Would `time_series_in_memory = false`
   (cache on, forward-only reads) or `MOI.Parameter`-style updates matter at NEM size?

---

## Probe results

The probe script (kept locally at `docs/superpowers/plans/2026-11-12-psi-anatomy-probe.jl`, not committed) ran against upstream PSI `cfcb71b` with
PowerSystems 5.12.5, IS 3.6.3, HiGHS 1.26.1 and JuMP 1.32.1 on `c_sys5_re`.

| Claim | Result |
| --- | --- |
| (a) construction leaves units unchanged; `build!` switches them | Confirmed: `NATURAL_UNITS` after construction, `SYSTEM_BASE` after `build!` and after `Simulation` build |
| (b) standalone parameters are `Float64`; `Simulation` parameters are `VariableRef` | Confirmed: `built_for_recurrent_solves = false` / `true`; eltypes `Float64` / `VariableRef` |
| (c) per-step order | Confirmed (A6 listing) |
| standalone stepping recipe | Confirmed for time-series parameters (A10) |
| (d) forecast cache reads forward only | Confirmed: `InvalidValue` on re-reading window 1 |
| (e1) mixed-forecast check never fires | Confirmed: `Set([...]) ∈ Set(both names) == false` |
| (e2) undefined `$V` in the error message | Confirmed: `UndefVarError: V not defined in PowerSimulations` |

---

## Appendix: fork delta

The fork (`81c0259d`) is 48 commits ahead of its merge base `869e5a7` with upstream. 19 of them are
upstream commits already on `main`. **None of the 29 commits by ymiftah is on upstream `main`.**
Upstream's own changes since the merge base (6 files, mostly HVDC and `TransmissionInterface`) do not
touch parameters, time series or the update path.

| Fork-only mechanism | Fork location | Upstream equivalent | AEMSim users |
| --- | --- | --- | --- |
| `ConstraintCoefficientParameter` + `add_coefficient_target!` / `_apply_coefficient_targets!` (`set_normalized_coefficient` per step) | fork:parameters/coefficient_parameters.jl; fork:core/parameters.jl:548 | none | tie-break, interconnector losses, FCAS slopes (aemsim:formulations/tie_break.jl:249-250, interconnector_losses.jl:358, fcas.jl:380-386; aemsim:psi_compat.jl:150-197) |
| `TimeSeriesCostParameter` + `add_cost_target!` / `_apply_cost_targets!` (objective variant terms); `has_variant_contributors` | fork:parameters/cost_parameters.jl; fork:core/parameters.jl:557 | none (`ObjectiveFunctionParameter` on offer curves only) | energy, MNSP, FCAS and constraint-slack band prices (aemsim:formulations/energy_offers.jl:202, mnsp.jl:405, fcas.jl:774, generic_constraints.jl:524) |
| `add_parameters!(…; meta, time_series_name)` | fork:parameters/add_parameters.jl:1-84 | none | aemsim:formulations/dispatch.jl:156-281, fcas.jl:148-162, energy_offers.jl:172-173, mnsp.jl:229, tie_break.jl:77, fixed_loads.jl:43 |
| `NetworkModel.slack_cost` | fork:core/network_model.jl:27-122 | none | aemsim:problems/nem_dispatch.jl:66 |
| cost series through the model cache; service-only `MarketBidCost`; in-memory reads without a metadata lookup; `is_milp` cached; store dataset name escaping | various | none | indirect |

`_unwrap_for_param` and `calc_additional_axes` are **upstream** hooks
(`calc_additional_axes` at psi:parameters/add_parameters.jl:614-728, `_unwrap_for_param` at 729-768), not fork additions.
