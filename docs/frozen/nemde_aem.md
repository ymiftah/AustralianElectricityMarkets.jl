<!-- frozen source=a5846f621f773f1ac9ef4b937709c44a66c8647bd425086dadb3eb3d2051ba2e -->
```@meta
EditURL = "../../literate/tutorials/nemde_aem.jl"
```

````julia
begin
    using AustralianElectricityMarkets
    using AustralianElectricityMarketsSimulations
    using PowerSystems
    using PowerSimulations
    using JuMP
    using HiGHS
    using DataFrames
    using Dates
    using CairoMakie
end;

import PowerSystems as PSY
import PowerSimulations as PSI
import AustralianElectricityMarketsSimulations as AEMSim
import AustralianElectricityMarkets as AEM

````

# [Building it with AEM and AEMSim](@id nemde-aem)

[The previous page](@ref nemde-psi) solves an energy-only market using PowerSimulations.jl (PSI).
This page includes FCAS, losses and generic constraints in the toy market of
[the JuMP model](@ref nemde-jump), using `AustralianElectricityMarkets` and
`AustralianElectricityMarketsSimulations`. It then compares dispatch, flows and prices
with the JuMP example.

!!! note "References"
    The market rules behind each formulation are in AEMO's
    [*FCAS Model in NEMDE*](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf)
    and *Constraint Violation Penalty Factors*; see [References](@ref nemde-aem-references).

## Step 1: the market as a `System`

For real markets, [`nem_system`](@ref) reads NEMWEB data into a `PowerSystems.jl` `System`
(see [The National Electricity Market](@ref)). Here we use the tutorial's two-region toy system.

````julia
sys = toy_system(market; nem = true)
````

```@raw html
<table>
  <thead>
    <tr class = "title">
      <td colspan = "2" style = "font-size: x-large; font-weight: bold; text-align: center;">System</td>
    </tr>
    <tr class = "columnLabelRow">
      <th style = "font-weight: bold; text-align: left;">Property</th>
      <th style = "font-weight: bold; text-align: left;">Value</th>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">Name</td>
      <td style = "text-align: left;"></td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Description</td>
      <td style = "text-align: left;"></td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">System Units Base</td>
      <td style = "text-align: left;">SYSTEM_BASE</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Base Power</td>
      <td style = "text-align: left;">100.0</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Base Frequency</td>
      <td style = "text-align: left;">60.0</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Num Components</td>
      <td style = "text-align: left;">10</td>
    </tr>
  </tbody>
</table>

<table>
  <thead>
    <tr class = "title">
      <td colspan = "2" style = "font-size: x-large; font-weight: bold; text-align: center;">Static Components</td>
    </tr>
    <tr class = "columnLabelRow">
      <th style = "font-weight: bold; text-align: left;">Type</th>
      <th style = "font-weight: bold; text-align: left;">Count</th>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">ACBus</td>
      <td style = "text-align: left;">2</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">Area</td>
      <td style = "text-align: left;">2</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">AreaInterchange</td>
      <td style = "text-align: left;">1</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">PowerLoad</td>
      <td style = "text-align: left;">2</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">RenewableDispatch</td>
      <td style = "text-align: left;">1</td>
    </tr>
    <tr class = "dataRow">
      <td style = "text-align: left;">ThermalStandard</td>
      <td style = "text-align: left;">2</td>
    </tr>
  </tbody>
</table>

<table>
  <thead>
    <tr class = "title">
      <td colspan = "8" style = "font-size: x-large; font-weight: bold; text-align: center;">StaticTimeSeries Summary</td>
    </tr>
    <tr class = "columnLabelRow">
      <th style = "font-weight: bold; text-align: left;">owner_type</th>
      <th style = "font-weight: bold; text-align: left;">owner_category</th>
      <th style = "font-weight: bold; text-align: left;">name</th>
      <th style = "font-weight: bold; text-align: left;">time_series_type</th>
      <th style = "font-weight: bold; text-align: left;">initial_timestamp</th>
      <th style = "font-weight: bold; text-align: left;">resolution</th>
      <th style = "font-weight: bold; text-align: left;">count</th>
      <th style = "font-weight: bold; text-align: left;">time_step_count</th>
    </tr>
    <tr class = "columnLabelRow">
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">Dates.CompoundPeriod</th>
      <th style = "text-align: left;">Int64</th>
      <th style = "text-align: left;">Int64</th>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">PowerLoad</td>
      <td style = "text-align: left;">Component</td>
      <td style = "text-align: left;">max_active_power</td>
      <td style = "text-align: left;">SingleTimeSeries</td>
      <td style = "text-align: left;">2025-01-01T12:00:00</td>
      <td style = "text-align: left;">5 minutes</td>
      <td style = "text-align: left;">2</td>
      <td style = "text-align: left;">2</td>
    </tr>
  </tbody>
</table>
<table>
  <thead>
    <tr class = "title">
      <td colspan = "10" style = "font-size: x-large; font-weight: bold; text-align: center;">Forecast Summary</td>
    </tr>
    <tr class = "columnLabelRow">
      <th style = "font-weight: bold; text-align: left;">owner_type</th>
      <th style = "font-weight: bold; text-align: left;">owner_category</th>
      <th style = "font-weight: bold; text-align: left;">name</th>
      <th style = "font-weight: bold; text-align: left;">time_series_type</th>
      <th style = "font-weight: bold; text-align: left;">initial_timestamp</th>
      <th style = "font-weight: bold; text-align: left;">resolution</th>
      <th style = "font-weight: bold; text-align: left;">count</th>
      <th style = "font-weight: bold; text-align: left;">horizon</th>
      <th style = "font-weight: bold; text-align: left;">interval</th>
      <th style = "font-weight: bold; text-align: left;">window_count</th>
    </tr>
    <tr class = "columnLabelRow">
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">String</th>
      <th style = "text-align: left;">Dates.CompoundPeriod</th>
      <th style = "text-align: left;">Int64</th>
      <th style = "text-align: left;">Dates.CompoundPeriod</th>
      <th style = "text-align: left;">Dates.CompoundPeriod</th>
      <th style = "text-align: left;">Int64</th>
    </tr>
  </thead>
  <tbody>
    <tr class = "dataRow">
      <td style = "text-align: left;">PowerLoad</td>
      <td style = "text-align: left;">Component</td>
      <td style = "text-align: left;">max_active_power</td>
      <td style = "text-align: left;">DeterministicSingleTimeSeries</td>
      <td style = "text-align: left;">2025-01-01T12:00:00</td>
      <td style = "text-align: left;">5 minutes</td>
      <td style = "text-align: left;">2</td>
      <td style = "text-align: left;">10 minutes</td>
      <td style = "text-align: left;">5 minutes</td>
      <td style = "text-align: left;">1</td>
    </tr>
  </tbody>
</table>

```

A run `System` holds its inputs as raw five-minute series with one point beyond the last
dispatch interval, as `nem_system` reads them from NEMWEB. The toy clears the one interval `T0`,
so its series cover two stamps.

````julia
const STAMPS = [T0, T0 + RESOLUTION]
````

````
[ Info: Cleared all time series.

````

### The interconnector's loss model

Interconnector losses are shared between the two regions. The toy loss model uses a
quadratic curve with five linear segments.

````julia

attach_loss_model!(sys, market);
````

### Market data as time series

Energy offers, availability, telemetered ramp rates and metered initial output specify the unit's
feasible dispatch for the interval. For NEMWEB data, `set_market_bids!` and `set_unit_conditions!`
attach these inputs.

````julia

attach_energy_data!(sys, market);
````

### FCAS as a service

The thermal units offer `RAISE6SEC`. Each offer includes price bands and a trapezium
describing the FCAS capacity available at each energy dispatch level.

````julia
attach_fcas_data!(sys, market);
````

````

````

### Generic constraints

Generic constraints impose linear limits on energy dispatch, FCAS enablement and
interconnector flows. This example includes two regional FCAS requirements and a coal
dispatch limit.

````julia


attach_generic_constraints!(sys, market);
````

````

````

### The derived NEMDE inputs

`nem_system` ends by deriving the inputs the run reads from the raw ones: the offers referred to
the regional reference node, the effective FCAS trapeziums, the loss demand coefficients, the
tie-break scales, the starting output of each unit, and the five-minute forecast windows. That
stage has no public entry point, because `nem_system` always runs it; the toy calls the internal
function directly on its hand-built `System`, which then runs the one interval `T0`.

````julia
AEM._set_nemde_inputs!(sys)
dispatch_intervals(sys)
````

````
1-element Vector{Dates.DateTime}:
 2025-01-01T12:00:00
````

The `System` now holds the whole market:

````julia
DataFrame(
    type = [
        string(nameof(T)) for T in (
                PSY.Area, PSY.ACBus, PSY.ThermalStandard, PSY.RenewableDispatch, PSY.PowerLoad,
                PSY.AreaInterchange, FCASService, GenericConstraint,
            )
    ],
    count = [
        length(PSY.get_components(T, sys)) for T in (
                PSY.Area, PSY.ACBus, PSY.ThermalStandard, PSY.RenewableDispatch, PSY.PowerLoad,
                PSY.AreaInterchange, FCASService, GenericConstraint,
            )
    ],
)
````

```@raw html
<div><div style = "float: left;"><span>8×2 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">type</th><th style = "text-align: left;">count</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "Int64" style = "text-align: left;">Int64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">Area</td><td style = "text-align: right;">2</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">ACBus</td><td style = "text-align: right;">2</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">ThermalStandard</td><td style = "text-align: right;">2</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">RenewableDispatch</td><td style = "text-align: right;">1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">PowerLoad</td><td style = "text-align: right;">2</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">AreaInterchange</td><td style = "text-align: right;">1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">FCASService</td><td style = "text-align: right;">2</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">GenericConstraint</td><td style = "text-align: right;">3</td></tr></tbody></table></div>
```

## Step 2: the template

`template_nemde` builds the data-free problem template: `NEMDispatch` for each dispatch
device type, the regional balance with slacks, the interconnector losses, and one service model per
FCAS service and per generic constraint. `template_skipped_constraints` reports, without changing `sys`,
the constraints the run leaves out, and `PSI.validate_template` verifies the inputs and that the
template models every participant when the model is built.

````julia
template = template_nemde()
skipped = template_skipped_constraints(sys, template)
isempty(skipped)
````

````
true
````

## Step 3: build and solve

`AEMSim.NEMDispatchProblem` prices the regional balance slacks and every penalty at one Market
Price Cap, dated by the first interval.

````julia
model_psi = PSI.DecisionModel(
    AEMSim.NEMDispatchProblem, template, sys;
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false, "mip_rel_gap" => 0.0),
    initial_time = T0,
    name = "nemde_aem",
)
build_status = PSI.build!(model_psi; output_dir = mktempdir())

solve_status = PSI.solve!(model_psi)
````

````
InfrastructureSystems.Simulation.RunStatusModule.RunStatus.SUCCESSFULLY_FINALIZED = 0
````

## Step 4: results, checked against the JuMP model

Variables are in MW. Duals are per unit of the system base and per interval, so
`dual / (BASE_POWER * INTERVAL_H)` is \$/MWh. FCAS prices come from
`read_fcas_prices`, which sums the duals of the generic constraints that carry an
FCAS requirement.

````julia
results = PSI.OptimizationProblemResults(model_psi)
to_dollars_per_mwh(dual) = dual / (BASE_POWER * INTERVAL_H)

value_by_name(df) = Dict(Symbol(r.name) => r.value for r in eachrow(df))
psi_dispatch = merge(
    value_by_name(read_variable(results, "ActivePowerVariable__ThermalStandard")),
    value_by_name(read_variable(results, "ActivePowerVariable__RenewableDispatch")),
)
psi_price = Dict(
    r.name => to_dollars_per_mwh(r.value) for r in eachrow(read_dual(results, "CopperPlateBalanceConstraint__Area"))
)
psi_flow = only(read_variable(results, "FlowActivePowerVariable__AreaInterchange").value)
psi_loss = only(read_variable(results, "InterconnectorLossVariable__AreaInterchange").value)
psi_fcas_price = read_fcas_prices(results, sys; resolution = RESOLUTION)
constraint_duals = read_dual(results, "NEMConstraintLimit__GenericConstraint")
psi_limit_dual = to_dollars_per_mwh(only(constraint_duals[constraint_duals.name .== "N_COAL_LIMIT", :value]))
psi_objective = only(values(PSI.get_objective_value(results)))

reference = solve_toy_jump(toy_system(market), market);

comparison = DataFrame(
    quantity = [
        "COAL1 (MW)", "WIND1 (MW)", "GAS1 (MW)", "Flow NSW1 to VIC1 (MW)", "Loss (MW)",
        "NSW1 price (\$/MWh)", "VIC1 price (\$/MWh)",
        "NSW1 RAISE6SEC price (\$/MW/h)", "VIC1 RAISE6SEC price (\$/MW/h)",
        "N_COAL_LIMIT dual (\$/MWh)", "Objective (\$)",
    ],
    JuMP = [
        reference.dispatch[:COAL1], reference.dispatch[:WIND1], reference.dispatch[:GAS1],
        reference.flow, reference.loss, reference.price["NSW1"], reference.price["VIC1"],
        reference.generic["F_NSW_R6"], reference.generic["F_VIC_R6"], reference.generic["N_COAL_LIMIT"],
        reference.objective,
    ],
    AEMSim = [
        psi_dispatch[:COAL1], psi_dispatch[:WIND1], psi_dispatch[:GAS1], psi_flow, psi_loss,
        psi_price["NSW1"], psi_price["VIC1"],
        only(psi_fcas_price[psi_fcas_price.REGIONID .== "NSW1", :ROP]),
        only(psi_fcas_price[psi_fcas_price.REGIONID .== "VIC1", :ROP]),
        psi_limit_dual, psi_objective,
    ],
)
comparison.difference = comparison.AEMSim .- comparison.JuMP
comparison
````

```@raw html
<div><div style = "float: left;"><span>11×4 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">quantity</th><th style = "text-align: left;">JuMP</th><th style = "text-align: left;">AEMSim</th><th style = "text-align: left;">difference</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">COAL1 (MW)</td><td style = "text-align: right;">375.0</td><td style = "text-align: right;">375.0</td><td style = "text-align: right;">0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">WIND1 (MW)</td><td style = "text-align: right;">150.0</td><td style = "text-align: right;">150.0</td><td style = "text-align: right;">0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">GAS1 (MW)</td><td style = "text-align: right;">306.641</td><td style = "text-align: right;">306.641</td><td style = "text-align: right;">5.68434e-14</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">Flow NSW1 to VIC1 (MW)</td><td style = "text-align: right;">74.1797</td><td style = "text-align: right;">74.1797</td><td style = "text-align: right;">-4.26326e-14</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">Loss (MW)</td><td style = "text-align: right;">1.64062</td><td style = "text-align: right;">1.64062</td><td style = "text-align: right;">-6.66134e-16</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">NSW1 price ($/MWh)</td><td style = "text-align: right;">238.281</td><td style = "text-align: right;">238.281</td><td style = "text-align: right;">0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">VIC1 price ($/MWh)</td><td style = "text-align: right;">250.0</td><td style = "text-align: right;">250.0</td><td style = "text-align: right;">0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">NSW1 RAISE6SEC price ($/MW/h)</td><td style = "text-align: right;">8.0</td><td style = "text-align: right;">8.0</td><td style = "text-align: right;">0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">9</td><td style = "text-align: left;">VIC1 RAISE6SEC price ($/MW/h)</td><td style = "text-align: right;">12.0</td><td style = "text-align: right;">12.0</td><td style = "text-align: right;">0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">10</td><td style = "text-align: left;">N_COAL_LIMIT dual ($/MWh)</td><td style = "text-align: right;">-183.281</td><td style = "text-align: right;">-183.281</td><td style = "text-align: right;">0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">11</td><td style = "text-align: left;">Objective ($)</td><td style = "text-align: right;">4153.76</td><td style = "text-align: right;">4153.76</td><td style = "text-align: right;">9.09495e-13</td></tr></tbody></table></div>
```

Both models are the same program, so they agree: every dispatch, flow, price and the objective match to solver
tolerance.

````julia
@assert build_status == PSI.ModelBuildStatus.BUILT
@assert solve_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED
@assert maximum(abs, comparison.difference) < 1.0e-4
````

## Elastic constraints

Constraint violations incur a penalty based on the constraint violation penalty factor and
the Market Price Cap (AEMO, *Schedule of Constraint Violation Penalty Factors*, §1, pp. 3-4).
This prioritises which limits to relax if the inputs conflict. The total violation in the
toy solution is:

````julia
slack_total
````

````
0.0
````

Nothing is violated in the toy market, so the solution equals the JuMP
model of [the JuMP model](@ref nemde-jump), which carries only the generic constraint violations.

## From the toy to the real market

Everything above was assembled by hand to show the pieces. For real intervals:

1. `db = aem_connect()` and `populate(db, table, start, stop)` cache the NEMWEB tables.
2. `nem_system(db, NEMDEConfiguration(); date_range)` builds the populated `System`,
   including energy and FCAS offers, dispatch and energy limits, generic constraints and losses.
   It ends with the NEMDE input stage the toy called above, so the derived inputs and the
   five-minute forecast windows are already in place, and `dispatch_intervals(sys)` lists the
   intervals it can run.
3. The run pre-flight checks run when the model is built, and
   `template_skipped_constraints(sys, template)` reports the constraints left out.
4. Construct, build and run a PSI simulation of the dispatch intervals. `nem_dispatch_sequence`
   adds NEMDE's second, fast-start run to each interval when the `System` has a fast-start unit:

   ```julia
   steps = dispatch_intervals(sys)
   template = template_nemde()
   (; models, sequence) = nem_dispatch_sequence(
       AEMSim.NEMDispatchProblem, template, sys;
       optimizer = AEMSim.nemde_optimizer(), initial_time = first(steps),
   )
   simulation = PSI.Simulation(;
       name = "NEMDE", steps = length(steps), models, sequence,
       simulation_folder = mktempdir(), initial_time = first(steps),
   )
   PSI.build!(simulation; store_systems_in_results = false)
   PSI.execute!(simulation)
   results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch")
   ```
5. `read_solved_interval(results, sys)` and `read_constraint_violations(results, sys)` extract the
   solved quantities and constraint violations, and `compare_intervals` joins them with
   `read_published_interval` from the cache. [Running NEMDE dispatch](@ref run-nemde) runs
   these steps on real intervals.

Validate the study inputs before solving. `check_fcas_services(template, sys)`
verifies that every FCAS service has a corresponding model in the template,
`read_interconnector_loss_gaps(results, sys)` after a solve verifies that each solved loss lies on
the loss curve at the solved flow: its `gap_mw` column is zero.

````julia
check_fcas_services(template, sys)
read_interconnector_loss_gaps(results, sys)
````

```@raw html
<div><div style = "float: left;"><span>1×7 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">interconnector</th><th style = "text-align: left;">DateTime</th><th style = "text-align: left;">flow_mw</th><th style = "text-align: left;">solved_loss_mw</th><th style = "text-align: left;">curve_loss_mw</th><th style = "text-align: left;">gap_mw</th><th style = "text-align: left;">weighted_loss_price</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "Dates.DateTime" style = "text-align: left;">DateTime</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">NSW1-VIC1</td><td style = "text-align: left;">2025-01-01T12:00:00</td><td style = "text-align: right;">74.1797</td><td style = "text-align: right;">1.64062</td><td style = "text-align: right;">1.64062</td><td style = "text-align: right;">1.33227e-15</td><td style = "text-align: right;">244.141</td></tr></tbody></table></div>
```

!!! note "Example scope"
    This tutorial solves a single interval with thermal and wind generation, one contingency
    FCAS service and a toy loss curve. It omits scheduled consumption, batteries, regulation
    FCAS scaling, fast-start profiles and price processing. See
    [Fast-start dispatch](@ref nemde-fast-start) and the [formulation overview](@ref nemde-model)
    for those market concepts.

## [References](@id nemde-aem-references)

- AEMO, [*FCAS Model in NEMDE*](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf):
  the trapezium (§2-3), joint constraints and prices.
- AEMO, *Constraint Violation Penalty Factors*: the penalty of each constraint family.
- AEMO, *Marginal Loss Factors* and *Loss Factor Methodology*: the interconnector loss equations.
- [PowerSimulations.jl documentation](https://nrel-sienna.github.io/PowerSimulations.jl/stable/)
  and [PowerSystems.jl documentation](https://nrel-sienna.github.io/PowerSystems.jl/stable/).
