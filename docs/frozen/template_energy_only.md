<!-- frozen source=8cdeba68b705fcc59347c642c816ffc0e699f27d4d83033e07538402434e8494 -->
```@meta
EditURL = "../../literate/howto/template_energy_only.jl"
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

# [Energy-only template](@id template-energy-only)

This page runs the intervals of [Running NEMDE dispatch](@ref run-nemde) with the same run
interface. Only the preset-specific parts are new here.

The energy-only preset keeps the dispatch participants, their bid stacks and their ramp limits,
with the demand of each region. It has no interchanges, FCAS, generic constraints or tie-break,
so each region clears its own bid stack against its own demand. Ramp limits are always kept.
Tie-break is modelled only by the full `template_nemde()`.

## The data

The run reads the local cache and downloads nothing. Uncomment the loop below to cache January 2025.

````julia
db = aem_connect();
# for table in table_requirements(NEMDEConfiguration())
#     populate(db, table, Date(2025, 1, 1), Date(2025, 1, 3))
# end
````

We run three intervals of the morning of 2 January 2025, the same as the full run.

````julia
steps = DateTime(2025, 1, 2, 8, 5):DISPATCH_INTERVAL:DateTime(2025, 1, 2, 8, 15)
````

````
Dates.DateTime("2025-01-02T08:05:00"):Dates.Minute(5):Dates.DateTime("2025-01-02T08:15:00")
````

## The run `System`

The `System` is the NEMDE build of the full run. The preset uses only its bids and demand.

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

`template_energy_only()` is one call to the keyword builder of `template_nemde`. The presets are
run with `fast_start = false`, because fast start is an option of the sequence, not of the template.

````julia
template = template_energy_only();
(; models, sequence) = nem_dispatch_sequence(
    NEMDispatchProblem, template, sys;
    fast_start = false, optimizer = nemde_optimizer(; output_flag = false), initial_time = first(steps),
);
````

````
[ Info: Overriding time_series_cache_size because time series is stored in memory

````

## Simulate

As in the full run, the `PSI.Simulation` steps the model through the intervals.

````julia
simulation = PSI.Simulation(;
    name = "energy_only", steps = length(steps), models, sequence,
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

Regional prices are compared with the regional original price (ROP). Regions are not coupled
in this preset, so each regional price is set by its own bid stack. NEMDE couples the regions
through the interchanges, and a regional price diverges from the published one wherever that
coupling sets it.

````julia
results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch");
solved = read_solved_interval(results, sys);
comparison = compare_intervals(read_published_interval(db, steps), solved);

select(comparison.prices, :SETTLEMENTDATE, :REGIONID, :ROP_published, :ROP_solved)
````

```@raw html
<div><div style = "float: left;"><span>15×4 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">SETTLEMENTDATE</th><th style = "text-align: left;">REGIONID</th><th style = "text-align: left;">ROP_published</th><th style = "text-align: left;">ROP_solved</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "Dates.DateTime" style = "text-align: left;">DateTime</th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">NSW1</td><td style = "text-align: right;">57.0101</td><td style = "text-align: right;">-1000.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">QLD1</td><td style = "text-align: right;">112.75</td><td style = "text-align: right;">14319.9</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">SA1</td><td style = "text-align: right;">-38.2367</td><td style = "text-align: right;">-32.5</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">TAS1</td><td style = "text-align: right;">120.26</td><td style = "text-align: right;">2.625e6</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">VIC1</td><td style = "text-align: right;">-38.31</td><td style = "text-align: right;">-62.39</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">NSW1</td><td style = "text-align: right;">76.72</td><td style = "text-align: right;">-1000.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">QLD1</td><td style = "text-align: right;">122.95</td><td style = "text-align: right;">3997.49</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">SA1</td><td style = "text-align: right;">-35.0</td><td style = "text-align: right;">-31.95</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">9</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">TAS1</td><td style = "text-align: right;">120.26</td><td style = "text-align: right;">2.625e6</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">10</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">VIC1</td><td style = "text-align: right;">-34.8519</td><td style = "text-align: right;">-60.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">11</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">NSW1</td><td style = "text-align: right;">76.72</td><td style = "text-align: right;">-1000.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">12</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">QLD1</td><td style = "text-align: right;">85.7998</td><td style = "text-align: right;">994.51</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">13</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">SA1</td><td style = "text-align: right;">-42.5</td><td style = "text-align: right;">-33.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">14</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">TAS1</td><td style = "text-align: right;">120.26</td><td style = "text-align: right;">2.625e6</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">15</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">VIC1</td><td style = "text-align: right;">-42.2751</td><td style = "text-align: right;">-66.3</td></tr></tbody></table></div>
```

Tasmania imports over Basslink in NEMDE. On its own it runs short, its balance is met by the
deficit slack, and its price is the energy deficit penalty, 150 times the Market Price Cap. NSW
exports in NEMDE. Here it keeps that generation, and its marginal bid falls to the Market Floor
Price of -1000 \$/MWh. The other regions clear on their own bid stacks. `read_constraint_violations`
shows the deficit:

````julia
read_constraint_violations(results, sys)
````

```@raw html
<div><div style = "float: left;"><span>12×6 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">family</th><th style = "text-align: left;">name</th><th style = "text-align: left;">DateTime</th><th style = "text-align: left;">MW</th><th style = "text-align: left;">direction</th><th style = "text-align: left;">variable</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "Dates.DateTime" style = "text-align: left;">DateTime</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">area_balance</td><td style = "text-align: left;">TAS1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">26.8307</td><td style = "text-align: left;">up</td><td style = "text-align: left;">SystemBalanceSlackUp__Area</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">energy_max_avail</td><td style = "text-align: left;">TARRALEA</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">0.2</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__HydroDispatch__energy_limit|max_avail</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">energy_max_avail</td><td style = "text-align: left;">YARWUN_1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">0.84</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__ThermalStandard__energy_limit|max_avail</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">energy_uigf</td><td style = "text-align: left;">STARHLWF</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">1.0e-5</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__RenewableDispatch__energy_limit|uigf</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">unit_ramp</td><td style = "text-align: left;">SWAN_E</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">0.415833</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__ThermalStandard__unit_ramp|up</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">area_balance</td><td style = "text-align: left;">TAS1</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">16.5618</td><td style = "text-align: left;">up</td><td style = "text-align: left;">SystemBalanceSlackUp__Area</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">energy_max_avail</td><td style = "text-align: left;">TARRALEA</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">0.2</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__HydroDispatch__energy_limit|max_avail</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">energy_max_avail</td><td style = "text-align: left;">YARWUN_1</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">0.38</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__ThermalStandard__energy_limit|max_avail</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">9</td><td style = "text-align: left;">unit_ramp</td><td style = "text-align: left;">SWAN_E</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">0.415833</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__ThermalStandard__unit_ramp|up</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">10</td><td style = "text-align: left;">area_balance</td><td style = "text-align: left;">TAS1</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">28.8814</td><td style = "text-align: left;">up</td><td style = "text-align: left;">SystemBalanceSlackUp__Area</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">11</td><td style = "text-align: left;">energy_max_avail</td><td style = "text-align: left;">TARRALEA</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">0.1</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__HydroDispatch__energy_limit|max_avail</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">12</td><td style = "text-align: left;">unit_ramp</td><td style = "text-align: left;">SWAN_E</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">0.415833</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__ThermalStandard__unit_ramp|up</td></tr></tbody></table></div>
```

`comparison_summary` gives one row per compared quantity. A deficit price dominates the
energy price error. The interchange and FCAS rows have no paired values, because the preset models neither.

````julia
comparison_summary(comparison)
````

```@raw html
<div><div style = "float: left;"><span>5×9 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">metric</th><th style = "text-align: left;">n_rows</th><th style = "text-align: left;">n_paired</th><th style = "text-align: left;">n_missing</th><th style = "text-align: left;">n_nonfinite</th><th style = "text-align: left;">mae</th><th style = "text-align: left;">rmse</th><th style = "text-align: left;">max_abs_gap</th><th style = "text-align: left;">bias</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">energy_price</td><td style = "text-align: right;">15</td><td style = "text-align: right;">15</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">5.26462e5</td><td style = "text-align: right;">1.17389e6</td><td style = "text-align: right;">2.62488e6</td><td style = "text-align: right;">5.26024e5</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">dispatch_mw</td><td style = "text-align: right;">1479</td><td style = "text-align: right;">1404</td><td style = "text-align: right;">75</td><td style = "text-align: right;">0</td><td style = "text-align: right;">8.06721</td><td style = "text-align: right;">29.0279</td><td style = "text-align: right;">308.533</td><td style = "text-align: right;">-0.221293</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">interconnector_flow_mw</td><td style = "text-align: right;">18</td><td style = "text-align: right;">0</td><td style = "text-align: right;">18</td><td style = "text-align: right;">0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">interconnector_losses_mw</td><td style = "text-align: right;">18</td><td style = "text-align: right;">0</td><td style = "text-align: right;">18</td><td style = "text-align: right;">0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">fcas_price</td><td style = "text-align: right;">150</td><td style = "text-align: right;">0</td><td style = "text-align: right;">150</td><td style = "text-align: right;">0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td></tr></tbody></table></div>
```

Next: [Lossless interconnectors](@ref template-interconnected), which adds the interchanges.
