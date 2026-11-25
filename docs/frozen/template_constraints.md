<!-- frozen source=955bfaae2c5748540f6efc234a9d9f53571ac5b671bed28d43f844f88a744abe -->
```@meta
EditURL = "../../literate/howto/template_constraints.jl"
```

````julia
begin
    using AustralianElectricityMarkets
    using AustralianElectricityMarketsData: populate
    using AustralianElectricityMarketsSimulations
    using Chain
    using DataFrames
    using Dates
    import PowerSimulations as PSI
end;
````

# [Generic constraints](@id template-constraints)

This page runs the intervals of [Running NEMDE dispatch](@ref run-nemde) with the same run
interface. Only the preset-specific parts are new here.

The preset is the interconnector-loss run with every generic constraint added and no FCAS
market. It has no counterpart among the nempy examples. Constraints with FCAS terms cannot clear
without the FCAS market, so they are left out and reported as `:unmodeled_fcas_service`.

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
template = template_constraints();
(; models, sequence) = nem_dispatch_sequence(
    NEMDispatchProblem, template, sys;
    fast_start = false, optimizer = nemde_optimizer(; output_flag = false), initial_time = first(steps),
);
````

````
[ Info: Overriding time_series_cache_size because time series is stored in memory

````

The constraints the run leaves out, and why, are reported without changing `sys`:

````julia
skipped = template_skipped_constraints(sys, template);
@chain skipped begin
    groupby(:reason)
    combine(nrow => :n_constraints)
end
````

```@raw html
<div><div style = "float: left;"><span>2×2 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">reason</th><th style = "text-align: left;">n_constraints</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "Symbol" style = "text-align: left;">Symbol</th><th title = "Int64" style = "text-align: left;">Int64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">unmodeled_fcas_service</td><td style = "text-align: right;">142</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">no_available_device</td><td style = "text-align: right;">2</td></tr></tbody></table></div>
```

`:no_available_device` marks a constraint whose contributing devices are all unavailable.
`n_missing` counts the terms of the constraint that the run cannot model.

The first few:

````julia
first(skipped, 5)
````

```@raw html
<div><div style = "float: left;"><span>5×3 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">constraint</th><th style = "text-align: left;">reason</th><th style = "text-align: left;">n_missing</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "Symbol" style = "text-align: left;">Symbol</th><th title = "Int64" style = "text-align: left;">Int64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">D_I+BIP_ML2_L1@2024-07-11#1</td><td style = "text-align: left;">unmodeled_fcas_service</td><td style = "text-align: right;">592</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">D_I+GFT_TG_R1@2024-07-11#1</td><td style = "text-align: left;">unmodeled_fcas_service</td><td style = "text-align: right;">592</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">D_I+NIL_MG2_R1@2024-05-13#1</td><td style = "text-align: left;">unmodeled_fcas_service</td><td style = "text-align: right;">592</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">D_I+NIL_MG_R1@2024-05-13#1</td><td style = "text-align: left;">unmodeled_fcas_service</td><td style = "text-align: right;">592</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">D_I+TTS_TG_R1@2024-07-11#1</td><td style = "text-align: left;">unmodeled_fcas_service</td><td style = "text-align: right;">592</td></tr></tbody></table></div>
```

A constraint can also be left out on purpose. `exclude_constraints` maps the name of each
constraint to the reason it is recorded with. The `System` is not changed:

```julia
template_constraints(; exclude_constraints = Dict("<NAME>" => :my_reason))
```

## Simulate

````julia
simulation = PSI.Simulation(;
    name = "constraints", steps = length(steps), models, sequence,
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

````julia
results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch");
solved = read_solved_interval(results, sys);
comparison = compare_intervals(read_published_interval(db, steps), solved);

select(comparison.prices, :SETTLEMENTDATE, :REGIONID, :ROP_published, :ROP_solved)
````

```@raw html
<div><div style = "float: left;"><span>15×4 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">SETTLEMENTDATE</th><th style = "text-align: left;">REGIONID</th><th style = "text-align: left;">ROP_published</th><th style = "text-align: left;">ROP_solved</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "Dates.DateTime" style = "text-align: left;">DateTime</th><th title = "String" style = "text-align: left;">String</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">NSW1</td><td style = "text-align: right;">57.0101</td><td style = "text-align: right;">57.01</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">QLD1</td><td style = "text-align: right;">112.75</td><td style = "text-align: right;">112.75</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">SA1</td><td style = "text-align: right;">-38.2367</td><td style = "text-align: right;">-38.2367</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">TAS1</td><td style = "text-align: right;">120.26</td><td style = "text-align: right;">120.26</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: left;">VIC1</td><td style = "text-align: right;">-38.31</td><td style = "text-align: right;">-38.31</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">NSW1</td><td style = "text-align: right;">76.72</td><td style = "text-align: right;">76.72</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">QLD1</td><td style = "text-align: right;">122.95</td><td style = "text-align: right;">122.95</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">SA1</td><td style = "text-align: right;">-35.0</td><td style = "text-align: right;">-35.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">9</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">TAS1</td><td style = "text-align: right;">120.26</td><td style = "text-align: right;">120.26</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">10</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: left;">VIC1</td><td style = "text-align: right;">-34.8519</td><td style = "text-align: right;">-34.8519</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">11</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">NSW1</td><td style = "text-align: right;">76.72</td><td style = "text-align: right;">76.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">12</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">QLD1</td><td style = "text-align: right;">85.7998</td><td style = "text-align: right;">84.9946</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">13</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">SA1</td><td style = "text-align: right;">-42.5</td><td style = "text-align: right;">-42.5</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">14</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">TAS1</td><td style = "text-align: right;">120.26</td><td style = "text-align: right;">120.26</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">15</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: left;">VIC1</td><td style = "text-align: right;">-42.2751</td><td style = "text-align: right;">-42.2751</td></tr></tbody></table></div>
```

````julia
comparison_summary(comparison)
````

```@raw html
<div><div style = "float: left;"><span>5×9 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">metric</th><th style = "text-align: left;">n_rows</th><th style = "text-align: left;">n_paired</th><th style = "text-align: left;">n_missing</th><th style = "text-align: left;">n_nonfinite</th><th style = "text-align: left;">mae</th><th style = "text-align: left;">rmse</th><th style = "text-align: left;">max_abs_gap</th><th style = "text-align: left;">bias</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">energy_price</td><td style = "text-align: right;">15</td><td style = "text-align: right;">15</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0.101687</td><td style = "text-align: right;">0.278898</td><td style = "text-align: right;">0.805209</td><td style = "text-align: right;">-0.101686</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">dispatch_mw</td><td style = "text-align: right;">1479</td><td style = "text-align: right;">1404</td><td style = "text-align: right;">75</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0.610111</td><td style = "text-align: right;">4.21409</td><td style = "text-align: right;">58.1563</td><td style = "text-align: right;">1.90951e-5</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">interconnector_flow_mw</td><td style = "text-align: right;">18</td><td style = "text-align: right;">18</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0.000577935</td><td style = "text-align: right;">0.00130989</td><td style = "text-align: right;">0.00417138</td><td style = "text-align: right;">0.000577935</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">interconnector_losses_mw</td><td style = "text-align: right;">18</td><td style = "text-align: right;">18</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">1.98867e-5</td><td style = "text-align: right;">6.73266e-5</td><td style = "text-align: right;">0.000284525</td><td style = "text-align: right;">1.6265e-5</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">fcas_price</td><td style = "text-align: right;">150</td><td style = "text-align: right;">0</td><td style = "text-align: right;">150</td><td style = "text-align: right;">0</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td><td style = "font-style: italic; text-align: right;">missing</td></tr></tbody></table></div>
```

## Constraint violations

`read_constraint_violations` lists every slack above tolerance, with its family, the constraint
or unit and the MW violated.

````julia
read_constraint_violations(results, sys)
````

```@raw html
<div><div style = "float: left;"><span>8×6 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">family</th><th style = "text-align: left;">name</th><th style = "text-align: left;">DateTime</th><th style = "text-align: left;">MW</th><th style = "text-align: left;">direction</th><th style = "text-align: left;">variable</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th><th title = "Dates.DateTime" style = "text-align: left;">DateTime</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "String" style = "text-align: left;">String</th><th title = "String" style = "text-align: left;">String</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">energy_max_avail</td><td style = "text-align: left;">TARRALEA</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">0.2</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__HydroDispatch__energy_limit|max_avail</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">energy_max_avail</td><td style = "text-align: left;">YARWUN_1</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">0.84</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__ThermalStandard__energy_limit|max_avail</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">unit_ramp</td><td style = "text-align: left;">SWAN_E</td><td style = "text-align: left;">2025-01-02T08:05:00</td><td style = "text-align: right;">0.415833</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__ThermalStandard__unit_ramp|up</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">energy_max_avail</td><td style = "text-align: left;">TARRALEA</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">0.2</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__HydroDispatch__energy_limit|max_avail</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">energy_max_avail</td><td style = "text-align: left;">YARWUN_1</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">0.38</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__ThermalStandard__energy_limit|max_avail</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">unit_ramp</td><td style = "text-align: left;">SWAN_E</td><td style = "text-align: left;">2025-01-02T08:10:00</td><td style = "text-align: right;">0.415833</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__ThermalStandard__unit_ramp|up</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">energy_max_avail</td><td style = "text-align: left;">TARRALEA</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">0.1</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__HydroDispatch__energy_limit|max_avail</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">unit_ramp</td><td style = "text-align: left;">SWAN_E</td><td style = "text-align: left;">2025-01-02T08:15:00</td><td style = "text-align: right;">0.415833</td><td style = "text-align: left;">up</td><td style = "text-align: left;">NEMUnitSlack__ThermalStandard__unit_ramp|up</td></tr></tbody></table></div>
```

Next: [Running NEMDE dispatch](@ref run-nemde) runs the full model, with tie-break and FCAS.
