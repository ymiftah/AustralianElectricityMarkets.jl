# Overview of the NEM

The [National Electricity Market (NEM)](https://www.aemo.com.au/energy-systems/electricity/national-electricity-market-nem)
operates on one of the world’s longest interconnected power systems. It covers around
40,000 km of transmission lines and cables, supplying a population exceeding 23 million.

The NEM is a wholesale market where electricity is traded across five interconnected regions:
Queensland (QLD), New South Wales (NSW), Victoria (VIC), South Australia (SA), and Tasmania (TAS).
Each region acts as a separate pricing zone, and prices can diverge when the transmission lines
(interconnectors) between them become congested.

## Simple usage

This package handles the download of data from the [NEMWEB Archive](https://www.aemo.com.au/energy-systems/electricity/national-electricity-market-nem/data-nem/market-data-nemweb)
and the parsing of the data into a System from `PowerSystems.jl`.
At the moment only a simple zonal network model is available (a nodal model with physical lines is a work-in-progress),
which allows to model a simple economic dispatch.
By default, the package will create a hidden folder `.aem_cache` in the home directory, and save the data into
parquet files.

````@example build_system
begin
    using AustralianElectricityMarkets
    using TidierDB
    using Dates
    using PowerSystems
    using DataFrames
    using Chain
    using CairoMakie, AlgebraOfGraphics
end


# Initialise a connection to manage the market data via duckdb
db = aem_connect(duckdb());

# Download data from AEMO's NEMWEB's Monthly archive
date_range = Date(2025, 1, 1):Date(2025, 1, 2)

# Download the data from the monthly archive, saving them locally
# in parquet files.
# Only the data requirements for a RegionalNetworkConfiguration are downloaded.
tables = table_requirements(RegionalNetworkConfiguration())
map(tables) do table
    fetch_table_data(table, date_range)
end;
nothing #hide
````

Once the data is downloaded, a few utility functions allow direct parsing of key quantities,
such as a table of all units registered in the NEM, or the region zonal operational demand

````@example build_system
# read all units
units = read_units(db)

capacity_by_fuel = @chain units begin
    select(:DUID, :REGISTEREDCAPACITY, :CO2E_ENERGY_SOURCE, :REGIONID)
    groupby([:CO2E_ENERGY_SOURCE, :REGIONID])
    combine(:REGISTEREDCAPACITY => (x -> sum(x) / 1000) => :installed_capacity_gw)
    dropmissing
    sort!(:installed_capacity_gw)
    # Ignore marginal sources
    subset!(:installed_capacity_gw => ByRow(>=(0.1)))
end

spec = mapping(
    :REGIONID,
    :installed_capacity_gw => "Installed capacity [GW]",
    stack = :CO2E_ENERGY_SOURCE,
    color = :CO2E_ENERGY_SOURCE => "Fuel source"
) * visual(
    BarPlot, alpha = 0.8,
)
fig = data(capacity_by_fuel) * spec
draw(
    fig,
    figure = (;
        title = "Installed capacity in the National Electricity Market by energy source",
    ),
    scales(Color = (; palette = from_continuous(:Paired_12)))
)
````

Read the demand for each state. In the NEM, this is referred to as **Operational Demand**,
which is the demand met by local scheduled and semi-scheduled generation, plus net imports
from other regions. It excludes "behind-the-meter" rooftop PV, which instead appears as a
reduction in operational demand.

````@example build_system
demand = read_demand(db)

begin
    spec = data(
        subset(demand, :SETTLEMENTDATE => ByRow(x -> (Date(2025, 1, 20) <= x <= Date(2025, 1, 31))))
    )
    spec *= mapping(:SETTLEMENTDATE => "Date", :TOTALDEMAND => "Total Demand [MW]", color = :REGIONID => "State")
    spec *= visual(Lines)
    figure_options = (;
        title = "Regional demand in each Australian state",
        subtitle = "Period of January 20th 2025 to January 31st 2025",
    )
    draw(spec; figure = figure_options)
end
````

Australia has a fairly high penetration of PV, which at times exceed a state's total
demand for electricity (in SA in particular).

````@example build_system
begin
    spec = data(
        subset(demand, :SETTLEMENTDATE => ByRow(x -> (Date(2025, 1, 20) <= x <= Date(2025, 1, 31))))
    )
    spec *= mapping(:SETTLEMENTDATE => "Date", :SS_SOLAR_AVAILABILITY => "Total Demand [MW]", color = :REGIONID => "State")
    spec *= visual(Lines)
    figure_options = (;
        title = "Solar generation from semi-scheduled units per state",
        subtitle = "Period of January 20th  2025 to January 31st 2025",
    )
    draw(spec; figure = figure_options)
end
````

## Integration with PowerSystems.jl

The main purpose of this package is to provide the data required for instantiating systems with
`PowerSystems.jl` and leverage the ecosystem of power systems modelling developed by NREL-Sienna.

````@example build_system
# Instantiate the system
sys = nem_system(db, RegionalNetworkConfiguration())
````

Users can then interact with the system with all `PowerSystems` utilities

````@example build_system
# Explore the thermal generators
thermal = @chain get_components(ThermalGen, sys) |> DataFrame begin
    select!([:name, :fuel, :prime_mover_type, :base_power])
    groupby(:fuel)
    combine(:base_power => sum => :installed_capacity_mw)
end
````

Get information for a specific unit

````@example build_system
gen = get_components_by_name(ThermalGen, sys, "JLA02") |> first
````

Check the prime mover type

````@example build_system
get_prime_mover_type(gen)
````

Check the rating in natural units

````@example build_system
with_units_base(sys, "NATURAL_UNITS") do
    get_rating(gen)
end
````
