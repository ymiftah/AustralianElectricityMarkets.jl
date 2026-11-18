<!-- frozen source=c6e381309c0f7b2551cd0a29cce60dd6bd87c5cc4065e13d3fb12ff2af03c97a -->
```@meta
EditURL = "../../literate/howto/template_interconnected.jl"
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

# [Lossless interconnectors](@id template-interconnected)

This page runs the intervals of [Running NEMDE dispatch](@ref run-nemde) with the same run
interface. Only the preset-specific parts are new here.

The preset adds the interchanges to the energy-only run, lossless. Each interchange keeps its
flow limits: the flow stays within IMPORTLIMIT and EXPORTLIMIT, and a violation is penalised
under AEMO's Constraint Violation Penalty item 5, "Interconnector Capacity Limit". No loss is
taken, so the loss columns are `missing`.

A lossless run is a study setting. NEMDE always applies the loss model. Without losses, regional
prices separate only where a flow limit binds. NEMDE's prices also carry marginal losses and the
generic constraints, which this preset leaves out, so prices and flows differ from the published
ones. An MNSP, such as Basslink, is a
regulated flow within its limits here, with no MNSP offers. It is the lossless counterpart of
the nempy interchange example, whose constant 5 percent loss is not modelled.

## The data

The run reads the local cache and downloads nothing. Uncomment the loop below to cache January 2025.

````julia
db = aem_connect();
# for table in table_requirements(NEMDEConfiguration())
#     populate(db, table, Date(2025, 1, 1), Date(2025, 1, 3))
# end

steps = DateTime(2025, 1, 2, 8, 5):DISPATCH_INTERVAL:DateTime(2025, 1, 2, 8, 15)
````

````
Dates.DateTime("2025-01-02T08:05:00"):Dates.Minute(5):Dates.DateTime("2025-01-02T08:15:00")
````

## The run `System`

````julia
horizon = first(steps):DISPATCH_INTERVAL:(last(steps) + 2DISPATCH_INTERVAL)
sys = nem_system(db, NEMDEConfiguration(); date_range = horizon);
````

````
[ Info: parsing buses
[ Info: parsing loads
[ Info: parsing branches
[ Info: parsing generators
[ Info: parsing batteries
[ Info: parsing scheduled loads
[ Info: parsing interconnectors/area interchanges / transmission interface
[ Info: rating 595.0 MW for T-V-MNSP1 is outside the expected range (min = 141.0, max = 344.0) MW for Line at a 138.0 kV Voltage level.

````

## The template and the decision model

The presets are run with `fast_start = false`, because fast start is an option of the sequence.

````julia
template = template_interconnected();
(; models, sequence) = nem_dispatch_sequence(
    NEMDispatchProblem, template, sys;
    fast_start = false, optimizer = nemde_optimizer(; output_flag = false), initial_time = first(steps),
);
````

````
[ Info: Overriding time_series_cache_size because time series is stored in memory

````

## Simulate

````julia
simulation = PSI.Simulation(;
    name = "interconnected", steps = length(steps), models, sequence,
    simulation_folder = mktempdir(), initial_time = first(steps),
);
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

## Compare with NEMDE

Interchange flows are compared with the published flows. The losses are `missing` on the solved
side, because the lossless model has no loss variable.

````julia
results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch");
solved = read_solved_interval(results, sys);
comparison = compare_intervals(read_published_interval(db, steps), solved);

select(comparison.prices, :SETTLEMENTDATE, :REGIONID, :ROP_published, :ROP_solved)
````

```@raw html
<div><div style = "float: left;"><span>15×4 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">SETTLEMENTDATE</th><th style = "text-align: left;">REGIONID</th><th style = "text-align: left;">ROP_published</th><th style = "text-align: left;">ROP_solved</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "Dates.DateTime" style = "text-align: left;">DateTime</th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">NSW1</td><td style = "text-align: right;">57.0101</td><td style = "text-align: right;">-33.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">QLD1</td><td style = "text-align: right;">112.75</td><td style = "text-align: right;">-33.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">SA1</td><td style = "text-align: right;">-38.2367</td><td style = "text-align: right;">-33.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">TAS1</td><td style = "text-align: right;">120.26</td><td style = "text-align: right;">120.26</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">VIC1</td><td style = "text-align: right;">-38.31</td><td style = "text-align: right;">-33.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">NSW1</td><td style = "text-align: right;">76.72</td><td style = "text-align: right;">-32.25</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">QLD1</td><td style = "text-align: right;">122.95</td><td style = "text-align: right;">-32.25</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">SA1</td><td style = "text-align: right;">-35.0</td><td style = "text-align: right;">-32.25</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">9</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">TAS1</td><td style = "text-align: right;">120.26</td><td style = "text-align: right;">120.26</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">10</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">VIC1</td><td style = "text-align: right;">-34.8519</td><td style = "text-align: right;">-32.25</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">11</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">NSW1</td><td style = "text-align: right;">76.72</td><td style = "text-align: right;">-34.2</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">12</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">QLD1</td><td style = "text-align: right;">85.7998</td><td style = "text-align: right;">-34.2</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">13</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">SA1</td><td style = "text-align: right;">-42.5</td><td style = "text-align: right;">-34.2</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">14</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">TAS1</td><td style = "text-align: right;">120.26</td><td style = "text-align: right;">120.26</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">15</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">VIC1</td><td style = "text-align: right;">-42.2751</td><td style = "text-align: right;">-34.2</td></tr></tbody></table></div>
```

````julia
select(
    comparison.interconnectors, :SETTLEMENTDATE, :INTERCONNECTORID,
    :MWFLOW_published, :MWFLOW_solved, :MWLOSSES_published, :MWLOSSES_solved,
)
````

```@raw html
<div><div style = "float: left;"><span>18×6 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">SETTLEMENTDATE</th><th style = "text-align: left;">INTERCONNECTORID</th><th style = "text-align: left;">MWFLOW_published</th><th style = "text-align: left;">MWFLOW_solved</th><th style = "text-align: left;">MWLOSSES_published</th><th style = "text-align: left;">MWLOSSES_solved</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "Dates.DateTime" style = "text-align: left;">DateTime</th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">N-Q-MNSP1</td><td style = "text-align: right;">-18.9</td><td style = "text-align: right;">265.0</td><td style = "text-align: right;">0.20876</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">NSW1-QLD1</td><td style = "text-align: right;">662.161</td><td style = "text-align: right;">1056.06</td><td style = "text-align: right;">49.0933</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">T-V-MNSP1</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">-479.0</td><td style = "text-align: right;">25.6212</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">V-S-MNSP1</td><td style = "text-align: right;">174.566</td><td style = "text-align: right;">271.0</td><td style = "text-align: right;">23.9047</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">V-SA</td><td style = "text-align: right;">0.68202</td><td style = "text-align: right;">-160.789</td><td style = "text-align: right;">-0.00131</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">VIC1-NSW1</td><td style = "text-align: right;">-784.271</td><td style = "text-align: right;">-207.356</td><td style = "text-align: right;">2.78104</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">N-Q-MNSP1</td><td style = "text-align: right;">-20.1</td><td style = "text-align: right;">-265.0</td><td style = "text-align: right;">0.29606</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">NSW1-QLD1</td><td style = "text-align: right;">658.309</td><td style = "text-align: right;">1449.33</td><td style = "text-align: right;">48.9209</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">9</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">T-V-MNSP1</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">-479.0</td><td style = "text-align: right;">25.6212</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">10</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">V-S-MNSP1</td><td style = "text-align: right;">171.752</td><td style = "text-align: right;">-271.0</td><td style = "text-align: right;">22.9212</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">11</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">V-SA</td><td style = "text-align: right;">24.6963</td><td style = "text-align: right;">289.892</td><td style = "text-align: right;">0.01855</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">12</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">VIC1-NSW1</td><td style = "text-align: right;">-524.507</td><td style = "text-align: right;">-121.687</td><td style = "text-align: right;">-9.85654</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">13</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">N-Q-MNSP1</td><td style = "text-align: right;">-20.2</td><td style = "text-align: right;">-265.0</td><td style = "text-align: right;">0.30333</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">14</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">NSW1-QLD1</td><td style = "text-align: right;">541.53</td><td style = "text-align: right;">1278.94</td><td style = "text-align: right;">34.8942</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">15</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">T-V-MNSP1</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">-479.0</td><td style = "text-align: right;">25.6212</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">16</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">V-S-MNSP1</td><td style = "text-align: right;">170.155</td><td style = "text-align: right;">271.0</td><td style = "text-align: right;">22.3817</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">17</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">V-SA</td><td style = "text-align: right;">42.4499</td><td style = "text-align: right;">-176.286</td><td style = "text-align: right;">0.01847</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">18</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">VIC1-NSW1</td><td style = "text-align: right;">-288.457</td><td style = "text-align: right;">56.9899</td><td style = "text-align: right;">-11.9391</td><td style = "font-style: italic; text-align: right;">missing</td></tr></tbody></table></div>
```

````julia
comparison_summary(comparison)
````

```@raw html
<div><div style = "float: left;"><span>5×9 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">metric</th><th style = "text-align: left;">n_rows</th><th style = "text-align: left;">n_paired</th><th style = "text-align: left;">n_missing</th><th style = "text-align: left;">n_nonfinite</th><th style = "text-align: left;">mae</th><th style = "text-align: left;">rmse</th><th style = "text-align: left;">max_abs_gap</th><th style = "text-align: left;">bias</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">energy_price</td><td style = "text-align: right;">15</td><td style = "text-align: right;">15</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">50.8749</td><td style = "text-align: right;">78.4065</td><td style = "text-align: right;">155.2</td><td style = "text-align: right;">-46.5717</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">dispatch_mw</td><td style = "text-align: right;">1479</td><td style = "text-align: right;">1404</td><td style = "text-align: right;">75</td><td style = "text-align: right;">0</td><td style = "text-align: right;">4.50931</td><td style = "text-align: right;">16.4909</td><td style = "text-align: right;">196.0</td><td style = "text-align: right;">-0.169816</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">interconnector_flow_mw</td><td style = "text-align: right;">18</td><td style = "text-align: right;">18</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">294.974</td><td style = "text-align: right;">372.627</td><td style = "text-align: right;">791.016</td><td style = "text-align: right;">148.79</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">interconnector_losses_mw</td><td style = "text-align: right;">18</td><td style = "text-align: right;">0</td><td style = "text-align: right;">18</td><td style = "text-align: right;">0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">fcas_price</td><td style = "text-align: right;">150</td><td style = "text-align: right;">0</td><td style = "text-align: right;">150</td><td style = "text-align: right;">0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td></tr></tbody></table></div>
```

Next: [Interconnector losses](@ref template-losses), which takes the loss model.
