<!-- frozen source=19934330cd6d074105b13c642727984b84a146ddb52480391e67382c7effba25 -->
```@meta
EditURL = "../../literate/howto/template_losses.jl"
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

# [Interconnector losses](@id template-losses)

This page runs the intervals of [Running NEMDE dispatch](@ref run-nemde) with the same run
interface. Only the preset-specific parts are new here.

The preset is the energy-only run with each interchange under its dynamic loss model. A flow
gives up the loss the loss curve takes at that flow, as NEMDE does. It has no FCAS, generic
constraints or tie-break. It corresponds to nempy's loss example.

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
template = template_losses();
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
    name = "losses", steps = length(steps), models, sequence,
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

The interchange flows and losses are compared with the published values.

````julia
results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch");
solved = read_solved_interval(results, sys);
comparison = compare_intervals(read_published_interval(db, steps), solved);

select(
    comparison.interconnectors, :SETTLEMENTDATE, :INTERCONNECTORID,
    :MWFLOW_published, :MWFLOW_solved, :MWLOSSES_published, :MWLOSSES_solved,
)
````

```@raw html
<div><div style = "float: left;"><span>18×6 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">SETTLEMENTDATE</th><th style = "text-align: left;">INTERCONNECTORID</th><th style = "text-align: left;">MWFLOW_published</th><th style = "text-align: left;">MWFLOW_solved</th><th style = "text-align: left;">MWLOSSES_published</th><th style = "text-align: left;">MWLOSSES_solved</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "Dates.DateTime" style = "text-align: left;">DateTime</th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">N-Q-MNSP1</td><td style = "text-align: right;">-18.9</td><td style = "text-align: right;">-265.0</td><td style = "text-align: right;">0.20876</td><td style = "text-align: right;">181.438</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">NSW1-QLD1</td><td style = "text-align: right;">662.161</td><td style = "text-align: right;">1677.55</td><td style = "text-align: right;">49.0933</td><td style = "text-align: right;">277.157</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">T-V-MNSP1</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">25.6212</td><td style = "text-align: right;">25.6212</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">V-S-MNSP1</td><td style = "text-align: right;">174.566</td><td style = "text-align: right;">-271.0</td><td style = "text-align: right;">23.9047</td><td style = "text-align: right;">108.464</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">V-SA</td><td style = "text-align: right;">0.68202</td><td style = "text-align: right;">213.672</td><td style = "text-align: right;">-0.00131</td><td style = "text-align: right;">4.95841</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">VIC1-NSW1</td><td style = "text-align: right;">-784.271</td><td style = "text-align: right;">-0.86795</td><td style = "text-align: right;">2.78104</td><td style = "text-align: right;">-0.0500156</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">N-Q-MNSP1</td><td style = "text-align: right;">-20.1</td><td style = "text-align: right;">-265.0</td><td style = "text-align: right;">0.29606</td><td style = "text-align: right;">181.438</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">NSW1-QLD1</td><td style = "text-align: right;">658.309</td><td style = "text-align: right;">1510.13</td><td style = "text-align: right;">48.9209</td><td style = "text-align: right;">227.491</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">9</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">T-V-MNSP1</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">25.6212</td><td style = "text-align: right;">25.6212</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">10</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">V-S-MNSP1</td><td style = "text-align: right;">171.752</td><td style = "text-align: right;">-271.0</td><td style = "text-align: right;">22.9212</td><td style = "text-align: right;">108.464</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">11</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">V-SA</td><td style = "text-align: right;">24.6963</td><td style = "text-align: right;">234.654</td><td style = "text-align: right;">0.01855</td><td style = "text-align: right;">5.8416</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">12</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">VIC1-NSW1</td><td style = "text-align: right;">-524.507</td><td style = "text-align: right;">62.6886</td><td style = "text-align: right;">-9.85654</td><td style = "text-align: right;">4.2335</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">13</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">N-Q-MNSP1</td><td style = "text-align: right;">-20.2</td><td style = "text-align: right;">-265.0</td><td style = "text-align: right;">0.30333</td><td style = "text-align: right;">181.438</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">14</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">NSW1-QLD1</td><td style = "text-align: right;">541.53</td><td style = "text-align: right;">1449.44</td><td style = "text-align: right;">34.8942</td><td style = "text-align: right;">211.464</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">15</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">T-V-MNSP1</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">25.6212</td><td style = "text-align: right;">25.6212</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">16</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">V-S-MNSP1</td><td style = "text-align: right;">170.155</td><td style = "text-align: right;">-271.0</td><td style = "text-align: right;">22.3817</td><td style = "text-align: right;">108.464</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">17</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">V-SA</td><td style = "text-align: right;">42.4499</td><td style = "text-align: right;">197.926</td><td style = "text-align: right;">0.01847</td><td style = "text-align: right;">3.61774</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">18</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">VIC1-NSW1</td><td style = "text-align: right;">-288.457</td><td style = "text-align: right;">252.787</td><td style = "text-align: right;">-11.9391</td><td style = "text-align: right;">21.7619</td></tr></tbody></table></div>
```

````julia
comparison_summary(comparison)
````

```@raw html
<div><div style = "float: left;"><span>5×9 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">metric</th><th style = "text-align: left;">n_rows</th><th style = "text-align: left;">n_paired</th><th style = "text-align: left;">n_missing</th><th style = "text-align: left;">n_nonfinite</th><th style = "text-align: left;">mae</th><th style = "text-align: left;">rmse</th><th style = "text-align: left;">max_abs_gap</th><th style = "text-align: left;">bias</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">energy_price</td><td style = "text-align: right;">15</td><td style = "text-align: right;">15</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">53.121</td><td style = "text-align: right;">76.866</td><td style = "text-align: right;">151.886</td><td style = "text-align: right;">-41.2412</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">dispatch_mw</td><td style = "text-align: right;">1479</td><td style = "text-align: right;">1404</td><td style = "text-align: right;">75</td><td style = "text-align: right;">0</td><td style = "text-align: right;">4.71869</td><td style = "text-align: right;">16.8806</td><td style = "text-align: right;">196.0</td><td style = "text-align: right;">1.02725</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">interconnector_flow_mw</td><td style = "text-align: right;">18</td><td style = "text-align: right;">18</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">407.259</td><td style = "text-align: right;">511.84</td><td style = "text-align: right;">1015.39</td><td style = "text-align: right;">177.784</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">interconnector_losses_mw</td><td style = "text-align: right;">18</td><td style = "text-align: right;">18</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">80.4388</td><td style = "text-align: right;">114.706</td><td style = "text-align: right;">228.064</td><td style = "text-align: right;">80.1242</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">fcas_price</td><td style = "text-align: right;">150</td><td style = "text-align: right;">0</td><td style = "text-align: right;">150</td><td style = "text-align: right;">0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td></tr></tbody></table></div>
```

Without generic constraints, flows run to their limits, far from NEMDE's, so the solved losses on
the loss curve are far larger than the published ones. The near-zero `gap_mw` below shows that
each loss lies on its curve.

## Loss gaps

`read_interconnector_loss_gaps` reads each interchange's solved loss against the loss curve
at its solved flow. The gap is the difference, so it is about zero when the solver takes the
loss the curve gives.

````julia
loss_gaps = read_interconnector_loss_gaps(results, sys)
````

```@raw html
<div><div style = "float: left;"><span>18×7 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">interconnector</th><th style = "text-align: left;">DateTime</th><th style = "text-align: left;">flow_mw</th><th style = "text-align: left;">solved_loss_mw</th><th style = "text-align: left;">curve_loss_mw</th><th style = "text-align: left;">gap_mw</th><th style = "text-align: left;">weighted_loss_price</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "Dates.DateTime" style = "text-align: left;">DateTime</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">V-SA</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">213.672</td><td style = "text-align: right;">4.95841</td><td style = "text-align: right;">4.95841</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-21.7955</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">V-SA</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">234.654</td><td style = "text-align: right;">5.8416</td><td style = "text-align: right;">5.8416</td><td style = "text-align: right;">5.32907e-15</td><td style = "text-align: right;">-20.5461</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">V-SA</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">197.926</td><td style = "text-align: right;">3.61774</td><td style = "text-align: right;">3.61774</td><td style = "text-align: right;">-2.17604e-14</td><td style = "text-align: right;">-28.1501</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">V-S-MNSP1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">-271.0</td><td style = "text-align: right;">108.464</td><td style = "text-align: right;">108.464</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-21.7652</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">V-S-MNSP1</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">-271.0</td><td style = "text-align: right;">108.464</td><td style = "text-align: right;">108.464</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-20.5138</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">V-S-MNSP1</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">-271.0</td><td style = "text-align: right;">108.464</td><td style = "text-align: right;">108.464</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-28.1165</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">T-V-MNSP1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">25.6212</td><td style = "text-align: right;">25.6212</td><td style = "text-align: right;">-7.10543e-15</td><td style = "text-align: right;">120.26</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">T-V-MNSP1</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">25.6212</td><td style = "text-align: right;">25.6212</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">120.26</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">9</td><td style = "text-align: left;">T-V-MNSP1</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">25.6212</td><td style = "text-align: right;">25.6212</td><td style = "text-align: right;">-1.06581e-14</td><td style = "text-align: right;">120.26</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">10</td><td style = "text-align: left;">N-Q-MNSP1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">-265.0</td><td style = "text-align: right;">181.438</td><td style = "text-align: right;">181.438</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-25.1473</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">11</td><td style = "text-align: left;">N-Q-MNSP1</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">-265.0</td><td style = "text-align: right;">181.438</td><td style = "text-align: right;">181.438</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-23.9128</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">12</td><td style = "text-align: left;">N-Q-MNSP1</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">-265.0</td><td style = "text-align: right;">181.438</td><td style = "text-align: right;">181.438</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-33.8764</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">13</td><td style = "text-align: left;">VIC1-NSW1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">-0.86795</td><td style = "text-align: right;">-0.0500156</td><td style = "text-align: right;">-0.0500156</td><td style = "text-align: right;">9.57567e-14</td><td style = "text-align: right;">-22.2838</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">14</td><td style = "text-align: left;">VIC1-NSW1</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">62.6886</td><td style = "text-align: right;">4.2335</td><td style = "text-align: right;">4.2335</td><td style = "text-align: right;">4.88498e-14</td><td style = "text-align: right;">-21.1947</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">15</td><td style = "text-align: left;">VIC1-NSW1</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">252.787</td><td style = "text-align: right;">21.7619</td><td style = "text-align: right;">21.7619</td><td style = "text-align: right;">-3.55271e-14</td><td style = "text-align: right;">-29.8473</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">16</td><td style = "text-align: left;">NSW1-QLD1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">1677.55</td><td style = "text-align: right;">277.157</td><td style = "text-align: right;">277.157</td><td style = "text-align: right;">1.76215e-12</td><td style = "text-align: right;">-25.7076</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">17</td><td style = "text-align: left;">NSW1-QLD1</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">1510.13</td><td style = "text-align: right;">227.491</td><td style = "text-align: right;">227.491</td><td style = "text-align: right;">-6.82121e-13</td><td style = "text-align: right;">-24.4151</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">18</td><td style = "text-align: left;">NSW1-QLD1</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">1449.44</td><td style = "text-align: right;">211.464</td><td style = "text-align: right;">211.464</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-34.5452</td></tr></tbody></table></div>
```

## Thinning the loss curve

`loss_breakpoints` keeps at most `N` breakpoints of each interchange's loss model, always the first
and the last, with the interior thinned evenly by index. The `System` is not changed, and
`read_interconnector_loss_gaps` still reads the full curve, so its `gap_mw` column shows the
error the thinning adds.

This second run uses four breakpoints, in its own simulation folder.

````julia
thinned_template = template_losses(; loss_breakpoints = 4);
thinned = nem_dispatch_sequence(
    NEMDispatchProblem, thinned_template, sys;
    fast_start = false, optimizer = nemde_optimizer(; output_flag = false), initial_time = first(steps),
);
thinned_simulation = PSI.Simulation(;
    name = "losses_thinned", steps = length(steps), models = thinned.models, sequence = thinned.sequence,
    simulation_folder = mktempdir(), initial_time = first(steps),
);
thinned_build_status = PSI.build!(thinned_simulation; store_systems_in_results = false)
````

````
InfrastructureSystems.Simulation.SimulationBuildStatusModule.SimulationBuildStatus.BUILT = 0
````

````julia
thinned_execute_status = PSI.execute!(thinned_simulation)

thinned_results = PSI.get_decision_problem_results(PSI.SimulationResults(thinned_simulation), "dispatch");
thinned_loss_gaps = read_interconnector_loss_gaps(thinned_results, sys)
````

```@raw html
<div><div style = "float: left;"><span>18×7 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">interconnector</th><th style = "text-align: left;">DateTime</th><th style = "text-align: left;">flow_mw</th><th style = "text-align: left;">solved_loss_mw</th><th style = "text-align: left;">curve_loss_mw</th><th style = "text-align: left;">gap_mw</th><th style = "text-align: left;">weighted_loss_price</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "Dates.DateTime" style = "text-align: left;">DateTime</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">V-SA</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">209.81</td><td style = "text-align: right;">2.13065</td><td style = "text-align: right;">4.77933</td><td style = "text-align: right;">-2.64868</td><td style = "text-align: right;">-21.6037</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">V-SA</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">209.917</td><td style = "text-align: right;">1.97651</td><td style = "text-align: right;">4.6291</td><td style = "text-align: right;">-2.65259</td><td style = "text-align: right;">-20.2529</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">V-SA</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">194.255</td><td style = "text-align: right;">1.3664</td><td style = "text-align: right;">3.47161</td><td style = "text-align: right;">-2.10521</td><td style = "text-align: right;">-28.9734</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">V-S-MNSP1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">-271.0</td><td style = "text-align: right;">98.7011</td><td style = "text-align: right;">108.464</td><td style = "text-align: right;">-9.76293</td><td style = "text-align: right;">-21.5972</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">V-S-MNSP1</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">-271.0</td><td style = "text-align: right;">98.7011</td><td style = "text-align: right;">108.464</td><td style = "text-align: right;">-9.76293</td><td style = "text-align: right;">-20.2472</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">V-S-MNSP1</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">-271.0</td><td style = "text-align: right;">98.7011</td><td style = "text-align: right;">108.464</td><td style = "text-align: right;">-9.76293</td><td style = "text-align: right;">-28.9673</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">T-V-MNSP1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">22.4947</td><td style = "text-align: right;">25.6212</td><td style = "text-align: right;">-3.12653</td><td style = "text-align: right;">120.26</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">T-V-MNSP1</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">22.4947</td><td style = "text-align: right;">25.6212</td><td style = "text-align: right;">-3.12653</td><td style = "text-align: right;">120.26</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">9</td><td style = "text-align: left;">T-V-MNSP1</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">-478.0</td><td style = "text-align: right;">22.4947</td><td style = "text-align: right;">25.6212</td><td style = "text-align: right;">-3.12653</td><td style = "text-align: right;">120.26</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">10</td><td style = "text-align: left;">N-Q-MNSP1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">-265.0</td><td style = "text-align: right;">159.703</td><td style = "text-align: right;">181.438</td><td style = "text-align: right;">-21.7356</td><td style = "text-align: right;">-24.8536</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">11</td><td style = "text-align: left;">N-Q-MNSP1</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">-265.0</td><td style = "text-align: right;">159.703</td><td style = "text-align: right;">181.438</td><td style = "text-align: right;">-21.7356</td><td style = "text-align: right;">-23.3325</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">12</td><td style = "text-align: left;">N-Q-MNSP1</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">-265.0</td><td style = "text-align: right;">159.703</td><td style = "text-align: right;">181.438</td><td style = "text-align: right;">-21.7356</td><td style = "text-align: right;">-33.5211</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">13</td><td style = "text-align: left;">VIC1-NSW1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">14.4451</td><td style = "text-align: right;">0.944096</td><td style = "text-align: right;">0.920899</td><td style = "text-align: right;">0.0231973</td><td style = "text-align: right;">-22.4713</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">14</td><td style = "text-align: left;">VIC1-NSW1</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">93.6614</td><td style = "text-align: right;">6.21323</td><td style = "text-align: right;">6.52764</td><td style = "text-align: right;">-0.314412</td><td style = "text-align: right;">-21.0852</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">15</td><td style = "text-align: left;">VIC1-NSW1</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">264.104</td><td style = "text-align: right;">18.3662</td><td style = "text-align: right;">22.9864</td><td style = "text-align: right;">-4.62029</td><td style = "text-align: right;">-30.2526</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">16</td><td style = "text-align: left;">NSW1-QLD1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">1653.31</td><td style = "text-align: right;">310.094</td><td style = "text-align: right;">269.609</td><td style = "text-align: right;">40.4846</td><td style = "text-align: right;">-25.2861</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">17</td><td style = "text-align: left;">NSW1-QLD1</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">1522.64</td><td style = "text-align: right;">278.932</td><td style = "text-align: right;">231.168</td><td style = "text-align: right;">47.7635</td><td style = "text-align: right;">-23.7394</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">18</td><td style = "text-align: left;">NSW1-QLD1</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">1462.76</td><td style = "text-align: right;">265.095</td><td style = "text-align: right;">215.148</td><td style = "text-align: right;">49.9461</td><td style = "text-align: right;">-34.107</td></tr></tbody></table></div>
```

Next: [FCAS markets](@ref template-fcas), which adds the FCAS market.
