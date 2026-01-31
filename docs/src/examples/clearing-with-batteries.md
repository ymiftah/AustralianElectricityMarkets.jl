````@example clearing_with_batteries
begin
    using AustralianElectricityMarkets
    import AustralianElectricityMarkets.RegionModel as RM
    using PowerSystems
    using PowerSimulations
    using HydroPowerSimulations
    using StorageSystemsSimulations

    using Chain
    using DataFrames
    using AlgebraOfGraphics, CairoMakie
    using TidierDB
    using Dates
    using HiGHS
end
````

# Addition of batteries

In addition to thermal, renewable, and hydro generators, we now include storage units (batteries) in our market clearing problem. We use the `EnergyReservoirStorage` component and a `StorageDispatchWithReserves` model, which allows the optimizer to manage both charging and discharging while respecting energy limits.

Batteries in the NEM play an increasingly vital role. They can perform **Arbitrage**: charging
when electricity prices are low (e.g., during the middle of the day when solar is abundant)
and discharging when prices are high (e.g., during the evening peak). Furthermore, they
provide essential services like **FCAS** (Frequency Control Ancillary Services) to keep the
grid stable.

!!! info "FCAS is a work in progress"
    This package does not support yet the definition of Ancillary Services consistent with the NEM rules.
    Stay tuned for the inclusion of those in the future

## Setup the system

Initialise a connection to manage the market data via duckdb. In this example, we will look at a period in January 2025.

!!! note "Get the data first!"
    You will first need to download the data from the monthly archive, saving them locally
    in parquet files.

```julia
tables = table_requirements(RegionalNetworkConfiguration())
map(tables) do table
    fetch_table_data(table, Date(2025, 1, 1):Date(2025,1,31))
end;
```

````@example clearing_with_batteries
db = aem_connect(duckdb());
````

Instantiate the system using a regional network configuration.

````@example clearing_with_batteries
sys = nem_system(db, RegionalNetworkConfiguration())
````

Set the horizon and resolution for the simulation. Batteries are often more interesting to observe at higher resolutions or over longer periods where their energy constraints become relevant. Here we use a 30-minute interval over a 48-hour horizon.

````@example clearing_with_batteries
interval = Minute(30)
horizon = Hour(48)
start_date = DateTime(2025, 1, 3, 0, 0)
date_range = start_date:interval:(start_date + horizon)
@show date_range
````

Set deterministic time series for demand, renewables, hydro, and market bids.

````@example clearing_with_batteries
set_demand!(sys, db, date_range; resolution = interval)
set_renewable_pv!(sys, db, date_range; resolution = interval)
set_renewable_wind!(sys, db, date_range; resolution = interval)
set_hydro_limits!(sys, db, date_range; resolution = interval)
set_market_bids!(sys, db, date_range; resolution = interval)
````

Derive forecasts from the deterministic time series.

````@example clearing_with_batteries
transform_single_time_series!(
    sys,
    horizon,
    interval,
);

@show sys
````

## Setup the problem

````@example clearing_with_batteries
begin
    template = ProblemTemplate()
    set_device_model!(template, Line, StaticBranch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
    set_device_model!(template, HydroDispatch, HydroDispatchRunOfRiver)
    set_network_model!(template, NetworkModel(AreaBalancePowerModel; use_slacks = true))
    set_device_model!(template, AreaInterchange, StaticBranch)

    storage_model = DeviceModel(
        EnergyReservoirStorage,
        StorageDispatchWithReserves;
        attributes = Dict(
            "reservation" => true,
            "energy_target" => false,
            "cycling_limits" => false,
            "regularization" => false,
        ),
    )
    set_device_model!(template, storage_model)
    template
end
````

The dispatch problem is solved using the HiGHS solver.

````@example clearing_with_batteries
solver = optimizer_with_attributes(HiGHS.Optimizer, "mip_rel_gap" => 0.05)

problem = DecisionModel(template, sys; optimizer = solver, horizon = horizon)
build!(problem; output_dir = joinpath(tempdir(), "out"))
````

Solve the problem:

````@example clearing_with_batteries
solve!(problem)
````

Observe the results:

````@example clearing_with_batteries
res = OptimizationProblemResults(problem)
````

# Battery Behavior: BOWWBA1

Let's focus on the behavior of a specific battery, "BOWWBA1" (Bolivar Waste Water Treatment BESS), located in South Australia. South Australia is a world leader in battery integration, often relying on them to manage its high penetration of wind and solar.

We can examine the battery's charging (ActivePowerIn) and discharging (ActivePowerOut) cycles.

````@example clearing_with_batteries
begin
    batteries_in = read_variable(res, "ActivePowerInVariable__EnergyReservoirStorage")
    batteries_out = read_variable(res, "ActivePowerOutVariable__EnergyReservoirStorage")

    batteries_all = vcat(
        insertcols(batteries_in, :direction => "in"),
        insertcols(batteries_out, :direction => "out"),
    )

    bowwba1_power = subset(batteries_all, :name => ByRow(==("BOWWBA1")))

    plt = data(bowwba1_power) *
          mapping(:DateTime, :value, color = :direction) *
          visual(Lines)

    draw(plt; figure = (; size = (800, 400), title = "BOWWBA1 Active Power (MW)"))
end
````

We can also look at the State of Charge (SOC) of the battery over the simulation period to see how it fills and empties.

````@example clearing_with_batteries
begin
    soc = read_variable(res, "EnergyVariable__EnergyReservoirStorage")
    bowwba1_soc = subset(soc, :name => ByRow(==("BOWWBA1")))

    plt = data(bowwba1_soc) *
          mapping(:DateTime, :value) *
          visual(Lines)

    draw(plt; figure = (; size = (800, 400), title = "BOWWBA1 State of Charge (MWh)"))
end
````

# Regional Dispatch with Storage

Finally, let's see how batteries integrate into the overall generation mix across the regions. In the NEM's regulatory framework, batteries were historically treated as both a generator and a load. More recently, new categories like the **Integrated Resource Provider (IRP)** have been introduced to better reflect their dual nature.

In our results, batteries appear as a source of energy when discharging and a consumer of energy when charging.

````@example clearing_with_batteries
begin
    function filter_non_all_zero(df, group_by)
        gdf = groupby(df, group_by)
        is_all_zero = combine(gdf, :value => (x -> all(x == 0)) => :all_zero)
        subset!(is_all_zero, :all_zero => x -> .!x)
        return innerjoin(df, is_all_zero, on = group_by)
    end

    renewables = read_variable(res, "ActivePowerVariable__RenewableDispatch")
    thermal = read_variable(res, "ActivePowerVariable__ThermalStandard")
    hydro = read_variable(res, "ActivePowerVariable__HydroDispatch")

    ## Calculate net battery dispatch
    batteries_tot = @chain innerjoin(batteries_in, batteries_out, on = [:DateTime, :name]; makeunique = true) begin
        select!(:DateTime, :name, [:value, :value_1] => ((in_, out_) -> out_ - in_) => :value)
    end

    gens_long = vcat(renewables, thermal, hydro, batteries_tot)
    select!(gens_long, :DateTime, :name => :DUID, :value)

    by_fuel = @chain select(
        read_units(db),
        [:DUID, :STATIONID, :CO2E_ENERGY_SOURCE, :REGIONID]
    ) begin
        rightjoin(gens_long, on = :DUID)
        groupby([:CO2E_ENERGY_SOURCE, :REGIONID, :DateTime])
        combine(:value => sum => :value)
        subset(:value => ByRow(!=(0.0)))
        dropmissing!
        select!(
            :DateTime, :REGIONID, :CO2E_ENERGY_SOURCE => :Source, :value
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

    mapping_ = mapping(:DateTime, :value, color = :Source, layout = :REGIONID)
    demand = data(loads) * mapping_ * visual(Lines, linestyle = (:dash, :dense))
    generation = data(by_fuel) * mapping_ * visual(Lines)

    draw(
        demand + generation,
        scales(Color = (; palette = :tab10));
        figure = (; size = (1000, 800)),
        legend = (; position = :bottom),
    )
end
````
