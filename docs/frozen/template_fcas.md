<!-- frozen source=7041dee029daf86969e9b283f253e70a2138af8a6a96bd8d1831b70766088fb7 -->
```@meta
EditURL = "../../literate/howto/template_fcas.jl"
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

# [FCAS markets](@id template-fcas)

This page runs the intervals of [Running NEMDE dispatch](@ref run-nemde) with the same run
interface. Only the preset-specific parts are new here.

The preset is the interconnector-loss run with the FCAS market added. NEMDE models the FCAS
requirements as generic constraints, so the preset keeps those (`constraints = :fcas_requirements`)
and leaves out the other generic constraints. The preset has no tie-break. It corresponds to
nempy's FCAS example.

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
template = template_fcas();
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
    name = "fcas", steps = length(steps), models, sequence,
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

The FCAS prices are the regional prices of each bid type, compared with the published
regional original prices (ROP). The table shows the first interval; the summary covers all three.

````julia
results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch");
solved = read_solved_interval(results, sys);
comparison = compare_intervals(read_published_interval(db, steps), solved);

@chain comparison.fcas_prices begin
    subset(:SETTLEMENTDATE => ByRow(==(first(steps))))
    select(:REGIONID, :BIDTYPE, :ROP_published, :ROP_solved)
end
````

```@raw html
<div><div style = "float: left;"><span>50×4 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">REGIONID</th><th style = "text-align: left;">BIDTYPE</th><th style = "text-align: left;">ROP_published</th><th style = "text-align: left;">ROP_solved</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "BidType" style = "text-align: left;">BidType</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Union{Missing, Float64}" style = "text-align: left;">Float64?</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">NSW1</td><td style = "text-align: left;">BidType.RAISE6SEC = 2</td><td style = "text-align: right;">0.01</td><td style = "text-align: right;">0.1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">NSW1</td><td style = "text-align: left;">BidType.LOWER6SEC = 3</td><td style = "text-align: right;">0.1</td><td style = "text-align: right;">0.1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">NSW1</td><td style = "text-align: left;">BidType.RAISE60SEC = 4</td><td style = "text-align: right;">0.01</td><td style = "text-align: right;">0.1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">NSW1</td><td style = "text-align: left;">BidType.LOWER60SEC = 5</td><td style = "text-align: right;">0.39</td><td style = "text-align: right;">0.39</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">NSW1</td><td style = "text-align: left;">BidType.RAISE5MIN = 6</td><td style = "text-align: right;">0.1</td><td style = "text-align: right;">0.23</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">6</td><td style = "text-align: left;">NSW1</td><td style = "text-align: left;">BidType.LOWER5MIN = 7</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">7</td><td style = "text-align: left;">NSW1</td><td style = "text-align: left;">BidType.RAISEREG = 8</td><td style = "text-align: right;">5.0</td><td style = "text-align: right;">5.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">8</td><td style = "text-align: left;">NSW1</td><td style = "text-align: left;">BidType.LOWERREG = 9</td><td style = "text-align: right;">8.5</td><td style = "text-align: right;">11.89</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">9</td><td style = "text-align: left;">NSW1</td><td style = "text-align: left;">BidType.RAISE1SEC = 10</td><td style = "text-align: right;">0.86</td><td style = "text-align: right;">0.86</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">10</td><td style = "text-align: left;">NSW1</td><td style = "text-align: left;">BidType.LOWER1SEC = 11</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">11</td><td style = "text-align: left;">QLD1</td><td style = "text-align: left;">BidType.RAISE6SEC = 2</td><td style = "text-align: right;">0.01</td><td style = "text-align: right;">0.1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">12</td><td style = "text-align: left;">QLD1</td><td style = "text-align: left;">BidType.LOWER6SEC = 3</td><td style = "text-align: right;">0.1</td><td style = "text-align: right;">0.1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">13</td><td style = "text-align: left;">QLD1</td><td style = "text-align: left;">BidType.RAISE60SEC = 4</td><td style = "text-align: right;">0.01</td><td style = "text-align: right;">0.1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">14</td><td style = "text-align: left;">QLD1</td><td style = "text-align: left;">BidType.LOWER60SEC = 5</td><td style = "text-align: right;">0.39</td><td style = "text-align: right;">0.39</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">15</td><td style = "text-align: left;">QLD1</td><td style = "text-align: left;">BidType.RAISE5MIN = 6</td><td style = "text-align: right;">0.1</td><td style = "text-align: right;">0.23</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">16</td><td style = "text-align: left;">QLD1</td><td style = "text-align: left;">BidType.LOWER5MIN = 7</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">17</td><td style = "text-align: left;">QLD1</td><td style = "text-align: left;">BidType.RAISEREG = 8</td><td style = "text-align: right;">5.0</td><td style = "text-align: right;">5.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">18</td><td style = "text-align: left;">QLD1</td><td style = "text-align: left;">BidType.LOWERREG = 9</td><td style = "text-align: right;">8.5</td><td style = "text-align: right;">11.89</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">19</td><td style = "text-align: left;">QLD1</td><td style = "text-align: left;">BidType.RAISE1SEC = 10</td><td style = "text-align: right;">0.86</td><td style = "text-align: right;">0.86</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">20</td><td style = "text-align: left;">QLD1</td><td style = "text-align: left;">BidType.LOWER1SEC = 11</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">21</td><td style = "text-align: left;">SA1</td><td style = "text-align: left;">BidType.RAISE6SEC = 2</td><td style = "text-align: right;">0.01</td><td style = "text-align: right;">0.1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">22</td><td style = "text-align: left;">SA1</td><td style = "text-align: left;">BidType.LOWER6SEC = 3</td><td style = "text-align: right;">0.1</td><td style = "text-align: right;">0.1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">23</td><td style = "text-align: left;">SA1</td><td style = "text-align: left;">BidType.RAISE60SEC = 4</td><td style = "text-align: right;">0.01</td><td style = "text-align: right;">0.1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">24</td><td style = "text-align: left;">SA1</td><td style = "text-align: left;">BidType.LOWER60SEC = 5</td><td style = "text-align: right;">0.39</td><td style = "text-align: right;">0.39</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">25</td><td style = "text-align: left;">SA1</td><td style = "text-align: left;">BidType.RAISE5MIN = 6</td><td style = "text-align: right;">0.1</td><td style = "text-align: right;">0.23</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">26</td><td style = "text-align: left;">SA1</td><td style = "text-align: left;">BidType.LOWER5MIN = 7</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">27</td><td style = "text-align: left;">SA1</td><td style = "text-align: left;">BidType.RAISEREG = 8</td><td style = "text-align: right;">5.0</td><td style = "text-align: right;">5.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">28</td><td style = "text-align: left;">SA1</td><td style = "text-align: left;">BidType.LOWERREG = 9</td><td style = "text-align: right;">8.5</td><td style = "text-align: right;">11.89</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">29</td><td style = "text-align: left;">SA1</td><td style = "text-align: left;">BidType.RAISE1SEC = 10</td><td style = "text-align: right;">0.86</td><td style = "text-align: right;">0.86</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">30</td><td style = "text-align: left;">SA1</td><td style = "text-align: left;">BidType.LOWER1SEC = 11</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">31</td><td style = "text-align: left;">TAS1</td><td style = "text-align: left;">BidType.RAISE6SEC = 2</td><td style = "text-align: right;">0.38</td><td style = "text-align: right;">0.38</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">32</td><td style = "text-align: left;">TAS1</td><td style = "text-align: left;">BidType.LOWER6SEC = 3</td><td style = "text-align: right;">0.1</td><td style = "text-align: right;">0.1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">33</td><td style = "text-align: left;">TAS1</td><td style = "text-align: left;">BidType.RAISE60SEC = 4</td><td style = "text-align: right;">0.38</td><td style = "text-align: right;">0.38</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">34</td><td style = "text-align: left;">TAS1</td><td style = "text-align: left;">BidType.LOWER60SEC = 5</td><td style = "text-align: right;">0.38</td><td style = "text-align: right;">0.38</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">35</td><td style = "text-align: left;">TAS1</td><td style = "text-align: left;">BidType.RAISE5MIN = 6</td><td style = "text-align: right;">0.1</td><td style = "text-align: right;">0.23</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">36</td><td style = "text-align: left;">TAS1</td><td style = "text-align: left;">BidType.LOWER5MIN = 7</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">37</td><td style = "text-align: left;">TAS1</td><td style = "text-align: left;">BidType.RAISEREG = 8</td><td style = "text-align: right;">6.12</td><td style = "text-align: right;">6.12</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">38</td><td style = "text-align: left;">TAS1</td><td style = "text-align: left;">BidType.LOWERREG = 9</td><td style = "text-align: right;">2.64</td><td style = "text-align: right;">2.64</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">39</td><td style = "text-align: left;">TAS1</td><td style = "text-align: left;">BidType.RAISE1SEC = 10</td><td style = "text-align: right;">0.86</td><td style = "text-align: right;">0.86</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">40</td><td style = "text-align: left;">TAS1</td><td style = "text-align: left;">BidType.LOWER1SEC = 11</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">41</td><td style = "text-align: left;">VIC1</td><td style = "text-align: left;">BidType.RAISE6SEC = 2</td><td style = "text-align: right;">0.01</td><td style = "text-align: right;">0.1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">42</td><td style = "text-align: left;">VIC1</td><td style = "text-align: left;">BidType.LOWER6SEC = 3</td><td style = "text-align: right;">0.1</td><td style = "text-align: right;">0.1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">43</td><td style = "text-align: left;">VIC1</td><td style = "text-align: left;">BidType.RAISE60SEC = 4</td><td style = "text-align: right;">0.01</td><td style = "text-align: right;">0.1</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">44</td><td style = "text-align: left;">VIC1</td><td style = "text-align: left;">BidType.LOWER60SEC = 5</td><td style = "text-align: right;">0.39</td><td style = "text-align: right;">0.39</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">45</td><td style = "text-align: left;">VIC1</td><td style = "text-align: left;">BidType.RAISE5MIN = 6</td><td style = "text-align: right;">0.1</td><td style = "text-align: right;">0.23</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">46</td><td style = "text-align: left;">VIC1</td><td style = "text-align: left;">BidType.LOWER5MIN = 7</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-0.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">47</td><td style = "text-align: left;">VIC1</td><td style = "text-align: left;">BidType.RAISEREG = 8</td><td style = "text-align: right;">5.0</td><td style = "text-align: right;">5.0</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">48</td><td style = "text-align: left;">VIC1</td><td style = "text-align: left;">BidType.LOWERREG = 9</td><td style = "text-align: right;">8.5</td><td style = "text-align: right;">11.89</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">49</td><td style = "text-align: left;">VIC1</td><td style = "text-align: left;">BidType.RAISE1SEC = 10</td><td style = "text-align: right;">0.86</td><td style = "text-align: right;">0.86</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">50</td><td style = "text-align: left;">VIC1</td><td style = "text-align: left;">BidType.LOWER1SEC = 11</td><td style = "text-align: right;">0.0</td><td style = "text-align: right;">-0.0</td></tr></tbody></table></div>
```

````julia
comparison_summary(comparison)
````

```@raw html
<div><div style = "float: left;"><span>5×9 DataFrame</span></div><div style = "clear: both;"></div></div><div class = "data-frame" style = "overflow-x: scroll;"><table class = "data-frame" style = "margin-bottom: 6px;"><thead><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;">Row</th><th style = "text-align: left;">metric</th><th style = "text-align: left;">n_rows</th><th style = "text-align: left;">n_paired</th><th style = "text-align: left;">n_missing</th><th style = "text-align: left;">n_nonfinite</th><th style = "text-align: left;">mae</th><th style = "text-align: left;">rmse</th><th style = "text-align: left;">max_abs_gap</th><th style = "text-align: left;">bias</th></tr><tr class = "columnLabelRow"><th class = "stubheadLabel" style = "font-weight: bold; text-align: right;"></th><th title = "String" style = "text-align: left;">String</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Int64" style = "text-align: left;">Int64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th><th title = "Float64" style = "text-align: left;">Float64</th></tr></thead><tbody><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">1</td><td style = "text-align: left;">energy_price</td><td style = "text-align: right;">15</td><td style = "text-align: right;">15</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">53.0773</td><td style = "text-align: right;">76.8623</td><td style = "text-align: right;">151.175</td><td style = "text-align: right;">-41.3185</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">2</td><td style = "text-align: left;">dispatch_mw</td><td style = "text-align: right;">1479</td><td style = "text-align: right;">1404</td><td style = "text-align: right;">75</td><td style = "text-align: right;">0</td><td style = "text-align: right;">4.69217</td><td style = "text-align: right;">16.7485</td><td style = "text-align: right;">196.0</td><td style = "text-align: right;">1.02245</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">3</td><td style = "text-align: left;">interconnector_flow_mw</td><td style = "text-align: right;">18</td><td style = "text-align: right;">18</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">405.079</td><td style = "text-align: right;">508.842</td><td style = "text-align: right;">1015.39</td><td style = "text-align: right;">175.605</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">4</td><td style = "text-align: left;">interconnector_losses_mw</td><td style = "text-align: right;">18</td><td style = "text-align: right;">18</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">80.0643</td><td style = "text-align: right;">114.26</td><td style = "text-align: right;">228.064</td><td style = "text-align: right;">79.7498</td></tr><tr class = "dataRow"><td class = "rowLabel" style = "font-weight: bold; text-align: right;">5</td><td style = "text-align: left;">fcas_price</td><td style = "text-align: right;">150</td><td style = "text-align: right;">150</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0</td><td style = "text-align: right;">0.154667</td><td style = "text-align: right;">0.588862</td><td style = "text-align: right;">3.39</td><td style = "text-align: right;">0.0848</td></tr></tbody></table></div>
```

Next: [Generic constraints](@ref template-constraints), which models every generic constraint.
