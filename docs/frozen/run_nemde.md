<!-- frozen source=4cec71d4b20d2f30aa409d0f3c4f59d86e2d95ec2a9e258dbb14671340dbff42 -->
```@meta
EditURL = "../../literate/howto/run_nemde.jl"
```

````julia
begin
    using AustralianElectricityMarkets
    using AustralianElectricityMarketsData: populate
    using AustralianElectricityMarketsSimulations
    using DataFrames
    using Dates
    import PowerSimulations as PSI
end;
````

# [Running NEMDE dispatch](@id run-nemde)

This page runs a few real dispatch intervals with `AustralianElectricityMarketsSimulations`
and compares the solved prices, dispatch and flows with what NEMDE published. It follows the
run interface end to end:

```text
nem_system -> template_nemde -> nem_dispatch_sequence -> PSI.Simulation -> build! -> execute!
```

The formulation it solves is described in the [NEMDE formulation](@ref nemde-model) chapters,
and [Building it with AEM and AEMSim](@ref nemde-aem) assembles the same pieces by hand on a
toy market.

## The data

The run reads the local cache and downloads nothing. The tables it needs are those of
`table_requirements(NEMDEConfiguration())`; uncomment the loop below to cache January 2025.

````julia
db = aem_connect();
# for table in table_requirements(NEMDEConfiguration())
#     populate(db, table, Date(2025, 1, 1), Date(2025, 1, 3))
# end
````

We run three intervals of the morning of 2 January 2025. Timestamps are interval-ending
`SETTLEMENTDATE`s in market time (AEST).

````julia
steps = DateTime(2025, 1, 2, 8, 5):DISPATCH_INTERVAL:DateTime(2025, 1, 2, 8, 15)
````

````
Dates.DateTime("2025-01-02T08:05:00"):Dates.Minute(5):Dates.DateTime("2025-01-02T08:15:00")
````

## Step 1: the run `System`

`nem_system` with `NEMDEConfiguration` builds every NEMDE input: energy and FCAS offers,
unit conditions, generic constraints, interconnector losses and MNSP offers. Its date range
runs past the last run interval, because each five-minute forecast window holds the
next interval as well. The build ends with the run checks: a missing input fails here,
before any model is built.

````julia
horizon = first(steps):DISPATCH_INTERVAL:(last(steps) + 2DISPATCH_INTERVAL)
sys = nem_system(db, NEMDEConfiguration(); date_range = horizon);
dispatch_intervals(sys)
````

````
3-element Vector{Dates.DateTime}:
 2025-01-02T08:05:00
 2025-01-02T08:10:00
 2025-01-02T08:15:00
````

## Step 2: the template and the decision models

`template_nemde()` is the data-free problem template. `nem_dispatch_sequence` turns it into
the PowerSimulations decision models of the run and the sequence that runs them.
`nemde_optimizer()` is HiGHS with tight MIP gaps.

````julia
template = template_nemde();
(; models, sequence, dispatch, commitment) = nem_dispatch_sequence(
    NEMDispatchProblem, template, sys;
    optimizer = nemde_optimizer(; output_flag = false), initial_time = first(steps),
)
PSI.get_name.(PSI.get_decision_models(models))
````

````
2-element Vector{Symbol}:
 :fast_start_commitment
 :dispatch
````

When the `System` holds a fast-start unit, as here, each interval runs NEMDE's two runs at
the same timestamp, as [Fast-start dispatch](@ref nemde-fast-start) describes: the commitment
run without inflexibility profiles, then the dispatch run, which holds every fast-start unit
to the profile of the mode it ends the interval in. Results and prices are the dispatch
run's, named `"dispatch"`. Pass `fast_start = false` to build the single model instead.

`NEMDispatchProblem` is the **open-loop** run: every interval starts from AEMO's metered
output and observed state, so each interval is an independent solve that can be compared
with NEMDE's. `NEMClosedLoopDispatchProblem` is the **closed-loop** run: each interval
after the first starts from the previous solve instead. It answers what dispatch would have
done had the market followed the run, and its gap to NEMDE grows with the gap between the
solved and metered trajectories.

The constraints the run leaves out, for example those whose every device is unavailable,
are reported without changing `sys`:

````julia
template_skipped_constraints(sys, template)
````

```@raw html
<div><div style = "float: left;"><span>2×3 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">constraint</th><th style = "text-align: left;">reason</th><th style = "text-align: left;">n_missing</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "Symbol" style = "text-align: left;">Symbol</th><th title = "Int64" style = "text-align: left;">Int64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">N_WDR_NO_SCADA@2022-05-18#1</td><td style = "text-align: left;">no_available_device</td><td style = "text-align: right;">0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">V_WDR_NO_SCADA@2022-03-14#1</td><td style = "text-align: left;">no_available_device</td><td style = "text-align: right;">0</td></tr></tbody></table></div>
```

## Step 3: simulate

A `PSI.Simulation` steps the models through the intervals, updating the time-series
parameters in place instead of rebuilding the model.

````julia
simulation = PSI.Simulation(;
    name = "run", steps = length(steps), models, sequence,
    simulation_folder = mktempdir(), initial_time = first(steps),
)
build_status = PSI.build!(simulation; store_systems_in_results = false)
````

````
InfrastructureSystems.Simulation.SimulationBuildStatusModule.SimulationBuildStatus.BUILT = 0
````

````julia
execute_status = PSI.execute!(simulation)
````

````
InfrastructureSystems.Simulation.RunStatusModule.RunStatus.SUCCESSFULLY_FINALIZED = 0
````

## Step 4: compare with NEMDE

`read_solved_interval` reads the solved outcome in the keys and columns of
`read_published_interval`, so `compare_intervals` joins the two:

````julia
results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch");
solved = read_solved_interval(results, sys);
comparison = compare_intervals(read_published_interval(db, steps), solved);
````

Energy prices are compared with the regional original price (ROP), the price straight from
the optimisation, not the settlement price (RRP):

````julia
select(comparison.prices, :SETTLEMENTDATE, :REGIONID, :ROP_published, :ROP_solved)
````

```@raw html
<div><div style = "float: left;"><span>15×4 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">SETTLEMENTDATE</th><th style = "text-align: left;">REGIONID</th><th style = "text-align: left;">ROP_published</th><th style = "text-align: left;">ROP_solved</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "Dates.DateTime" style = "text-align: left;">DateTime</th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">NSW1</td><td style = "text-align: right;">57.0101</td><td style = "text-align: right;">57.01</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">QLD1</td><td style = "text-align: right;">112.75</td><td style = "text-align: right;">112.75</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">SA1</td><td style = "text-align: right;">-38.2367</td><td style = "text-align: right;">-38.2367</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">TAS1</td><td style = "text-align: right;">120.26</td><td style = "text-align: right;">120.26</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">VIC1</td><td style = "text-align: right;">-38.31</td><td style = "text-align: right;">-38.31</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">NSW1</td><td style = "text-align: right;">76.72</td><td style = "text-align: right;">76.72</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">QLD1</td><td style = "text-align: right;">122.95</td><td style = "text-align: right;">122.95</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">SA1</td><td style = "text-align: right;">-35.0</td><td style = "text-align: right;">-35.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">9</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">TAS1</td><td style = "text-align: right;">120.26</td><td style = "text-align: right;">120.26</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">10</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">VIC1</td><td style = "text-align: right;">-34.8519</td><td style = "text-align: right;">-34.8519</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">11</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">NSW1</td><td style = "text-align: right;">76.72</td><td style = "text-align: right;">76.72</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">12</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">QLD1</td><td style = "text-align: right;">85.7998</td><td style = "text-align: right;">85.7998</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">13</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">SA1</td><td style = "text-align: right;">-42.5</td><td style = "text-align: right;">-42.5</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">14</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">TAS1</td><td style = "text-align: right;">120.26</td><td style = "text-align: right;">120.26</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">15</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">VIC1</td><td style = "text-align: right;">-42.2751</td><td style = "text-align: right;">-42.2751</td></tr></tbody></table></div>
```

`comparison_summary` gives one row per compared quantity: energy prices, unit dispatch,
interconnector flows and losses and FCAS prices.

````julia
comparison_summary(comparison)
````

```@raw html
<div><div style = "float: left;"><span>5×9 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">metric</th><th style = "text-align: left;">n_rows</th><th style = "text-align: left;">n_paired</th><th style = "text-align: left;">n_missing</th><th style = "text-align: left;">n_nonfinite</th><th style = "text-align: left;">mae</th><th style = "text-align: left;">rmse</th><th style = "text-align: left;">max_abs_gap</th><th style = "text-align: left;">bias</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">energy_price</td><td style = "text-align: right;">15</td><td style = "text-align: right;">15</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">6.56414e-6</td><td style = "text-align: right;">1.70505e-5</td><td style = "text-align: right;">5.9e-5</td><td style = "text-align: right;">-5.1692e-6</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">dispatch_mw</td><td style = "text-align: right;">1479</td><td style = "text-align: right;">1404</td><td style = "text-align: right;">75</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0.0514373</td><td style = "text-align: right;">1.21826</td><td style = "text-align: right;">32.0566</td><td style = "text-align: right;">1.90951e-5</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">interconnector_flow_mw</td><td style = "text-align: right;">18</td><td style = "text-align: right;">18</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0.000578248</td><td style = "text-align: right;">0.00131043</td><td style = "text-align: right;">0.00417138</td><td style = "text-align: right;">0.000578248</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">interconnector_losses_mw</td><td style = "text-align: right;">18</td><td style = "text-align: right;">18</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">1.98873e-5</td><td style = "text-align: right;">6.73266e-5</td><td style = "text-align: right;">0.000284525</td><td style = "text-align: right;">1.62644e-5</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">fcas_price</td><td style = "text-align: right;">150</td><td style = "text-align: right;">150</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0.0086</td><td style = "text-align: right;">0.0268949</td><td style = "text-align: right;">0.13</td><td style = "text-align: right;">0.0086</td></tr></tbody></table></div>
```

The interconnector flows:

````julia
select(comparison.interconnectors, :SETTLEMENTDATE, :INTERCONNECTORID, :MWFLOW_published, :MWFLOW_solved)
````

```@raw html
<div><div style = "float: left;"><span>18×4 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">SETTLEMENTDATE</th><th style = "text-align: left;">INTERCONNECTORID</th><th style = "text-align: left;">MWFLOW_published</th><th style = "text-align: left;">MWFLOW_solved</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "Dates.DateTime" style = "text-align: left;">DateTime</th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">N-Q-MNSP1</td><td style = "text-align: right;">-18.9</td><td style = "text-align: right;">-18.9</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">NSW1-QLD1</td><td style = "text-align: right;">662.161</td><td style = "text-align: right;">662.161</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">T-V-MNSP1</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">-478.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">V-S-MNSP1</td><td style = "text-align: right;">174.566</td><td style = "text-align: right;">174.566</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">V-SA</td><td style = "text-align: right;">0.68202</td><td style = "text-align: right;">0.684295</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">VIC1-NSW1</td><td style = "text-align: right;">-784.271</td><td style = "text-align: right;">-784.271</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">N-Q-MNSP1</td><td style = "text-align: right;">-20.1</td><td style = "text-align: right;">-20.1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">NSW1-QLD1</td><td style = "text-align: right;">658.309</td><td style = "text-align: right;">658.309</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">9</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">T-V-MNSP1</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">-478.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">10</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">V-S-MNSP1</td><td style = "text-align: right;">171.752</td><td style = "text-align: right;">171.752</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">11</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">V-SA</td><td style = "text-align: right;">24.6963</td><td style = "text-align: right;">24.7005</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">12</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">VIC1-NSW1</td><td style = "text-align: right;">-524.507</td><td style = "text-align: right;">-524.507</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">13</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">N-Q-MNSP1</td><td style = "text-align: right;">-20.2</td><td style = "text-align: right;">-20.2</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">14</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">NSW1-QLD1</td><td style = "text-align: right;">541.53</td><td style = "text-align: right;">541.532</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">15</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">T-V-MNSP1</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">-478.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">16</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">V-S-MNSP1</td><td style = "text-align: right;">170.155</td><td style = "text-align: right;">170.155</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">17</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">V-SA</td><td style = "text-align: right;">42.4499</td><td style = "text-align: right;">42.4514</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">18</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">VIC1-NSW1</td><td style = "text-align: right;">-288.457</td><td style = "text-align: right;">-288.457</td></tr></tbody></table></div>
```

## Constraint violations

Almost every constraint is elastic, at a penalty set by AEMO's constraint violation
penalty factors. `read_constraint_violations` lists every slack above tolerance, with its
family, the constraint or unit and the MW violated. A violated constraint in the run is
the first thing to look at when a solved price departs from the published one.

````julia
read_constraint_violations(results, sys)
````

```@raw html
<div><div style = "float: left;"><span>8×6 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">family</th><th style = "text-align: left;">name</th><th style = "text-align: left;">DateTime</th><th style = "text-align: left;">MW</th><th style = "text-align: left;">direction</th><th style = "text-align: left;">variable</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "Dates.DateTime" style = "text-align: left;">DateTime</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">energy_max_avail</td><td style = "text-align: left;">TARRALEA</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">0.2</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__HydroDispatch__energy_limit|max_avail</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">energy_max_avail</td><td style = "text-align: left;">YARWUN_1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">0.84</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__ThermalStandard__energy_limit|max_avail</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">unit_ramp</td><td style = "text-align: left;">SWAN_E</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">0.415833</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__ThermalStandard__unit_ramp|up</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">energy_max_avail</td><td style = "text-align: left;">TARRALEA</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">0.2</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__HydroDispatch__energy_limit|max_avail</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">energy_max_avail</td><td style = "text-align: left;">YARWUN_1</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">0.38</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__ThermalStandard__energy_limit|max_avail</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">unit_ramp</td><td style = "text-align: left;">SWAN_E</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">0.415833</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__ThermalStandard__unit_ramp|up</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">energy_max_avail</td><td style = "text-align: left;">TARRALEA</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">0.1</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__HydroDispatch__energy_limit|max_avail</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">unit_ramp</td><td style = "text-align: left;">SWAN_E</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">0.415833</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__ThermalStandard__unit_ramp|up</td></tr></tbody></table></div>
```

## Simpler templates

`template_nemde()` is the full model. Its keyword builder takes parts out one at a time, and
five presets are one-line calls to it, each following one of the nempy examples:

| Preset | Interchanges | FCAS | Generic constraints | nempy example |
| --- | --- | --- | --- | --- |
| [`template_energy_only()`](@ref template-energy-only) | none | no | no | 1 and 2: bid stack, ramps |
| [`template_interconnected()`](@ref template-interconnected) | lossless | no | no | 3, its lossless counterpart (nempy's constant 5 percent loss is not modelled) |
| [`template_losses()`](@ref template-losses) | dynamic losses | no | no | 4: dynamic losses |
| [`template_fcas()`](@ref template-fcas) | dynamic losses | yes | FCAS requirements only | 5: FCAS markets |
| [`template_constraints()`](@ref template-constraints) | dynamic losses | no | all | none |

None of the presets has tie-break, which only the full `template_nemde()` models. Ramp
limits are always kept.

Each preset has its own how-to page, run with `fast_start = false`.

## Going further

- Run a whole trading day with `trading_day_steps(day)`, split by `dispatch_chunks` into
  ranges one `PSI.Simulation` can hold.
- The batch runner in `scripts/batch_run.jl` runs whole days, selected intervals or a
  random sample and writes the comparisons as CSV files; see
  [Batch runs and benchmark](@ref run-batch).
