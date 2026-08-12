module AustralianElectricityMarkets

using PowerSystems
using TidierDB
using HTTP, JSON3
using Dates
import TimeSeries: TimeArray, colnames
import PowerSystems as PSY
import InfrastructureSystems as IS

# exports
export HiveConfiguration, PyHiveConfiguration, fetch_table_data, list_available_tables
export NetworkConfiguration, table_requirements
export aem_connect
export nem_system
export RegionalNetworkConfiguration, FCASNetworkConfiguration

export read_hive
export read_interconnectors, read_units, read_demand, read_bids, read_energy_bids
export read_affine_heatrates,
    read_coal_prices, read_gas_prices, read_biomass_prices, read_isp_thermal_costs_parameters,
    read_isp_renewable_costs_parameters,
    read_isp_fixed_opex, read_isp_variable_opex
export set_demand!, set_renewable_pv!, set_renewable_wind!, set_market_bids!, set_hydro_limits!
export read_fcas_bids, add_fcas_reserves!, set_fcas_offers!, read_fcas_requirements
export FCAS_BID_TYPES, FCAS_CONTINGENCY_MARKETS, FCAS_REGULATION_MARKETS


# Write your package code here.
include("constants.jl")
include("configurations.jl")
include("data_utils.jl")
include("network_models/interface.jl")


include("AustralianElectricityMarketsData.jl")

# Export data module
using .AustralianElectricityMarketsData: PyHiveConfiguration, fetch_table_data, list_available_tables, read_affine_heatrates,
    read_coal_prices, read_gas_prices, read_biomass_prices, read_isp_thermal_costs_parameters,
    read_isp_renewable_costs_parameters, read_isp_fixed_opex, read_isp_variable_opex

# FCAS (Frequency Control Ancillary Services) types.
#
# Defined directly in this top-level module, NOT a nested submodule (despite the
# `RegionModel` precedent for network-configuration types): confirmed directly that PSY/IS's
# component-type lookup on JSON deserialize (`InfrastructureSystems.get_module`, via
# `Base.root_module`) only resolves top-level package names, not dotted submodule paths like
# `AustralianElectricityMarkets.FCAS` - nesting these `Reserve`/`DeviceParameter` subtypes in
# a submodule made `to_json`/`System(path)` round-trips throw `KeyError:
# Symbol("AustralianElectricityMarkets.FCAS") not found`. `RegionModel`'s own types don't hit
# this because they're never added as components to a `System` (so never serialized this
# way) - only genuinely serializable types need to live at this top level.
include("fcas/types.jl")
include("fcas/offers.jl")

export NEMFCASReserve, ContingencyFCASReserve, RegulationFCASReserve, FCASResponseTime,
    FCASTrapezium, FCASOffer, NEMMarketBidCost,
    get_region, set_region!, get_response_time, set_response_time!,
    get_enablement_min, get_low_breakpoint, get_high_breakpoint, get_enablement_max,
    get_max_avail, get_ramp_up_rate, get_ramp_down_rate,
    get_reserve_name, get_offer_curve, get_trapezium

# Modules
include("parser.jl")

# Parsing data into models
include("network_models/region_model.jl")

# Exports the network models implemented
using .RegionModel: RegionalNetworkConfiguration, FCASNetworkConfiguration

end
