begin
    using AustralianElectricityMarkets
    using TidierDB
    using Dates
    using PowerSystems
    using DataFrames
    using Chain
    using GLMakie, AlgebraOfGraphics
end

# # Overview of the NEM

# Initialise a connection to manage the market data via duckdb
db = connect(duckdb());

# Download data from AEMO's NEMWEB's Monthly archive
date_range = Date(2025, 1, 1):Date(2025, 1, 2)

# Download the data from the monthly archive, saving them locally
# in parquet files
# Only the data requirements for a RegionalNetworkconfiguration are downloaded.
fetch_table_data(date_range, RegionalNetworkConfiguration())

# read all units
units = read_units(db)

capacity_by_fuel = @chain units begin
    select(:DUID, :REGISTEREDCAPACITY, :CO2E_ENERGY_SOURCE, :REGIONID)
    groupby([:CO2E_ENERGY_SOURCE, :REGIONID])
    combine(:REGISTEREDCAPACITY => (x -> sum(x) / 1000) => :installed_capacity_gw)
    dropmissing
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
    fig, figure = (;
        title = "Installed capacity in the National Electricity Market by energy source",
    ),
    scales(Color = (; palette = from_continuous(:Paired_12)))
)

# Read the demand for each state
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

# Australia as a fairly high penetration of rooftop PV, which at times exceed a state's total
# demand for electricity (in SA in particular)
begin
    spec = data(
        subset(demand, :SETTLEMENTDATE => ByRow(x -> (Date(2025, 1, 20) <= x <= Date(2025, 1, 31))))
    )
    spec *= mapping(:SETTLEMENTDATE => "Date", :SS_SOLAR_AVAILABILITY => "Total Demand [MW]", color = :REGIONID => "State")
    spec *= visual(Lines)
    figure_options = (;
        title = "Solar generationfrom semi-scheduled units per state",
        subtitle = "Period of 20th January 2025 to 31st January 2025",
    )
    draw(spec; figure = figure_options)
end

## Integration with PowerSystems.jl

# Instantiate the system
sys = nem_system(db, RegionalNetworkConfiguration())


# Explore the Thermal generators
thermal = @chain get_components(ThermalGen, sys) |> DataFrame begin
    select!([:name, :fuel, :prime_mover_type, :base_power])
    groupby(:fuel)
    combine(:base_power => sum => :installed_capacity_mw)
end


# Get informations for a specific unit
gen = get_components_by_name(ThermalGen, sys, "JLA02")

active_power_mw = get_active_power(gen)
