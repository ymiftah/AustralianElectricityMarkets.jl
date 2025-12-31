module AustralianElectricityMarkets

using PowerSystems
using TidierDB
using HTTP, JSON3
using Dates
import TimeSeries: TimeArray, colnames

# exports
export PyHiveConfiguration, fetch_table_data, list_available_tables
export NetworkConfiguration, table_requirements
export nem_system
export RegionalNetworkConfiguration

export read_hive
export read_interconnectors, read_units, read_demand, read_bids
export read_affine_heatrates,
    read_coal_prices, read_gas_prices, read_biomass_prices, read_isp_thermal_costs_parameters
export set_demand!, set_renewable_pv!, set_renewable_wind!, set_market_bids!


# Write your package code here.
include("constants.jl")
include("configurations.jl")
include("geoutils.jl")
include("network_models/interface.jl")


include("AustralianElectricityMarketsData.jl")

# Export data module
using .AustralianElectricityMarketsData: PyHiveConfiguration, fetch_table_data, list_available_tables, read_affine_heatrates,
    read_coal_prices, read_gas_prices, read_biomass_prices, read_isp_thermal_costs_parameters

# Modules
include("parser.jl")

# Parsing data into models
include("network_models/region_model.jl")

# Exports the network models implemented
using .RegionModel: RegionalNetworkConfiguration

end
