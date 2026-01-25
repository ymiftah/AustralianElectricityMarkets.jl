````@example interchanges
begin
    using AustralianElectricityMarkets
    import AustralianElectricityMarkets.RegionModel
    using PowerSystems
    using PowerSimulations
    using HydroPowerSimulations

    using Chain
    using DataFrames
    using AlgebraOfGraphics, CairoMakie
    using TidierDB
    using Dates
    using HiGHS
end

RM = AustralianElectricityMarkets.RegionModel
````

# Setup the system

Initialise a connection to manage the market data via duckdb

!!! note "Get the data first!"
    You will first need to download the data from the monthly archive, saving them locally
    in parquet files.


    ```julia
    tables = table_requirements(RegionalNetworkConfiguration())
    map(tables) do table
        fetch_table_data(table, date_range)
    end;
    ```

    Only the data requirements for a RegionalNetworkconfiguration are downloaded.

````@example interchanges
db = aem_connect(duckdb());
nothing #hide
````

Instantiate the system

````@example interchanges
sys = nem_system(db, RegionalNetworkConfiguration())
````

Set the horizon to consider for the simulation

````@example interchanges
interval = Minute(5)
horizon = Hour(24)
start_date = DateTime(2025, 1, 1, 4, 0)
date_range = start_date:interval:(start_date + horizon)
@show date_range

map([:BIDDAYOFFER_D, :BIDPEROFFER_D]) do table
    fetch_table_data(table, date_range)
end;
nothing #hide
````

Set deterministic timseries

````@example interchanges
set_demand!(sys, db, date_range; resolution = interval)
set_renewable_pv!(sys, db, date_range; resolution = interval)
set_renewable_wind!(sys, db, date_range; resolution = interval)
set_hydro_limits!(sys, db, date_range; resolution = interval)
set_market_bids!(sys, db, date_range)
````

Derive forecasts from the deterministic timseries

````@example interchanges
transform_single_time_series!(
    sys,
    horizon,
    interval, # interval
);

@show sys
````

# Dispatch

`PowerSimulation.jl` provides different utilities to simulate an electricity system.

The following section demonstrates the definition of an economic dispatch problem, where
all units in the NEM need to to be dispatched at the lowest cost to meet the aggregate
demand at each region.

````@example interchanges

begin
    template = ProblemTemplate()
    set_device_model!(template, Line, StaticBranch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, ThermalStandard, ThermalBasicDispatch)
    set_device_model!(template, HydroDispatch, HydroDispatchRunOfRiver)
    set_network_model!(template, NetworkModel(AreaBalancePowerModel; use_slacks = true))
    set_device_model!(template, AreaInterchange, StaticBranch)
    template
end
````

The Economic Dispatch problem will be solved with open source solver HiGHS, and a relatively large mip gap
for the purposes of this example.

````@example interchanges
solver = optimizer_with_attributes(HiGHS.Optimizer, "mip_rel_gap" => 0.2)


problem = DecisionModel(template, sys; optimizer = solver, horizon = horizon)
build!(problem; output_dir = joinpath(tempdir(), "out"))
````

Solve the problem

````@example interchanges
solve!(problem)
````

Observe the results

````@example interchanges
res = OptimizationProblemResults(problem)
````

Lets observe how the units are dispatched

````@example interchanges
begin
    renewables = read_variable(res, "ActivePowerVariable__RenewableDispatch")
    thermal = read_variable(res, "ActivePowerVariable__ThermalStandard")
    hydro = read_variable(res, "ActivePowerVariable__HydroDispatch")
    gens_long = vcat(renewables, thermal, hydro)
    select!(gens_long, :DateTime, :name => :DUID, :value)

    by_fuel = @chain select(
        read_units(db),
        [:DUID, :STATIONID, :CO2E_ENERGY_SOURCE, :REGIONID]
    ) begin
        rightjoin(gens_long, on = :DUID)
        groupby([:CO2E_ENERGY_SOURCE, :REGIONID, :DateTime])
        combine(:value => sum => :value)
        subset(:value => ByRow(>(0.0)))
        dropmissing!
        select!(
            :DateTime, :REGIONID, :CO2E_ENERGY_SOURCE => :Source,
            :value
        )
    end


    loads = @chain res begin
        read_parameter("ActivePowerTimeSeriesParameter__PowerLoad")
        transform!(
            :name => ByRow(x -> split(x, " ")[1]) => :REGIONID
        )
        subset!(:REGIONID => ByRow(!=("SNOWY1")))
        insertcols!(
            :Source => "Region demand"
        )
        select!(
            :DateTime, :REGIONID, :Source,
            :value => ByRow(-) => :value
        )
    end


    demand = data(loads) * mapping(
        :DateTime, :value, color = :Source, layout = :REGIONID
    ) * visual(Lines, linestyle = (:dash, :dense))
    generation = data(by_fuel) * mapping(
        :DateTime, :value, color = :Source, layout = :REGIONID
    ) * visual(Lines)

    draw(
        demand + generation;
        figure = (; size = (1000, 800)),
        legend = (; position = :bottom)
    )
end
````

Let's observe the dispatch of a few thermal generators

````@example interchanges
function filter_non_all_zero(df, group_by, value)
    gdf = groupby(df, group_by)
    is_all_zero = combine(gdf, :value => (x -> all(x == 0)) => :all_zero)
    subset!(is_all_zero, :all_zero => x -> .!x)
    return innerjoin(df, is_all_zero, on = group_by)
end

begin
    thermals_non_zero = filter_non_all_zero(thermal, :name, :value)
    sample = first(unique(thermals_non_zero.name), 5)
    sample = subset!(thermals_non_zero, :name => ByRow(in(sample)))
    spec = data(sample) * mapping(:DateTime, :value, color = :name) * visual(Lines)
    draw(spec; figure = (; size = (500, 500)))
end
````

Let's observe the dispatch of a few renewable generators

````@example interchanges
begin
    renewables_non_zero = filter_non_all_zero(renewables, :name, :value)
    sample = first(unique(renewables_non_zero.name), 5)
    sample = subset!(renewables_non_zero, :name => ByRow(in(sample)))
    data(sample) * mapping(:DateTime, :value, color = :name) * visual(Lines) |> draw
end
````

Notice that most solar generators are actually **not** dispatched during the day here even
though the solar output is definitely non-zero.

````@example interchanges
begin
    ren = get_component(RenewableDispatch, sys, "COLEASF1")
    ts = get_time_series_array(Deterministic, ren, "max_active_power") |> DataFrame
    index, values = ts.timestamp, ts.A * 100
    fig = Figure()
    ax = Axis(fig[1, 1], xlabel = "timestamp", title = "Max active power [MW]", ylabel = "MW")
    lines!(index, values; label = "COLEASF1")
    axislegend(ax)
    fig
end
````

This was not observed in the Economic dispatch example, and is due to the fact that the market bids ( in the Australian Electricity market)
incorporate the on/off constraints: Coal power plant bid at lower costs than solar plants because
it is more expensive for them to turn off, and they know they should be able to recoup the losses at time of
low solar generation, where there is less competition.

````@example interchanges
begin
    interchange_flow = read_variable(res, "FlowActivePowerVariable__AreaInterchange")
    spec = data(interchange_flow) * mapping(:DateTime, :value => "Interchange flow (MW)", color = :name) * visual(Lines)
    draw(spec; figure = (; size = (500, 500)))
end
````

