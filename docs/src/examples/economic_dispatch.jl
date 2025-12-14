begin
    using AustralianElectricityMarkets
    using PowerSimulations
    using PowerSystems

    using Chain
    using DataFrames
    using AlgebraOfGraphics, CairoMakie
    using TidierDB
    using Dates
    using HiGHS
end


#=

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

=#
db = connect(duckdb());

# Instantiate the system
sys = nem_system(db, RegionalNetworkConfiguration())

# Set the horizon to consider for the simulation
date_range = Date(2025, 1, 1):Date(2025, 1, 2)
interval = Minute(30)
horizon = Hour(24)

# Set deterministic timseries
set_demand!(sys, db, date_range; resolution = interval)
set_renewable_pv!(sys, db, date_range; resolution = interval)
set_renewable_wind!(sys, db, date_range; resolution = interval)

# Derive forecasts from the deterministic timseries
transform_single_time_series!(
    sys,
    horizon, # horizon
    interval, # interval
);

@show sys

#=

# Economic dispatch

`PowerSimulation.jl` provides different utilities to simulate an electricity system.

The following section demonstrates the definition of an economic dispatch problem, where
all units in the NEM need to to be dispatched at the lowest cost to meet the aggregate
demand at each region.

=#

template = template_economic_dispatch()

# The Economic Dispatch problem will be solved with open source solver HiGHS, and a relatively large mip gap
# for the purposes of this example.
solver = optimizer_with_attributes(HiGHS.Optimizer, "mip_rel_gap" => 0.05)


problem = DecisionModel(template, sys; optimizer = solver, horizon = horizon)
build!(problem)

# Solve the problem
solve!(problem)


# Observe the results
res = OptimizationProblemResults(problem)

# Lets observe how the units are dispatched
begin
    renewables = read_variable(res, "ActivePowerVariable__RenewableDispatch")
    thermal = read_variable(res, "ActivePowerVariable__ThermalStandard")
    gens = innerjoin(renewables, thermal, on = :DateTime)
    gens_long = stack(gens, Not([:DateTime]))


    by_fuel = @chain select(
        read_units(db),
        [:DUID, :STATIONID, :CO2E_ENERGY_SOURCE, :REGIONID]
    ) begin
        rightjoin(gens_long, on = :DUID => :variable)
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
        select(Not("SNOWY1 Load"))
        stack()
        transform!(
            :variable => ByRow(x -> split(x, " ")[1]) => :REGIONID
        )
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
        figure = (; size = (1000, 400)),
        legend = (; position = :bottom)
    )
end

# Let's observe the dispatch of a few thermal generators
begin
    thermals_non_zero = thermal[:, filter(x -> (x == "DateTime" || any(thermal[!, x] .> 0)), names(thermal))]
    sample = select(thermals_non_zero, 1:6)
    cols = names(select(sample, Not(:DateTime)))
    data(sample) * mapping(:DateTime, cols, color = dims(1)) * visual(Lines) |> draw
end

# Let's observe the dispatch of a few renewable generators
begin
    renewables_non_zero = renewables[:, filter(x -> (x == "DateTime" || any(renewables[!, x] .> 0)), names(renewables))]
    sample = select(renewables_non_zero, 1:6)
    cols = names(select(sample, Not(:DateTime)))
    data(sample) * mapping(:DateTime, cols, color = dims(1)) * visual(Lines) |> draw
end
