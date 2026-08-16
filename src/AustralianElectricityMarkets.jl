module AustralianElectricityMarkets

using PowerSystems
using DuckDB
using Dates
import TimeSeries: TimeArray, colnames
import PowerSystems as PSY
import InfrastructureSystems as IS

using AustralianElectricityMarketsData

# exports
export HiveConfiguration, list_available_tables, populate
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
export read_fcas_bids, add_fcas_reserves!, set_fcas_offers!, read_fcas_requirements,
    read_fcas_prices, read_fcas_dispatch, read_prices
export FCAS_BID_TYPES, FCAS_CONTINGENCY_MARKETS, FCAS_REGULATION_MARKETS
export BidType


# Write your package code here.
include("constants.jl")
include("units.jl")
include("network_models/interface.jl")

# FCAS (Frequency Control Ancillary Services) types - include early because parser.jl depends on FCASResponseTime and FCASOffer
include("fcas/types.jl")
include("fcas/offers.jl")

include("parser.jl")

# Export data module
using .AustralianElectricityMarketsData: populate, get_table, list_available_tables, ARCHIVE_MONTH_PARTITION
using .AustralianElectricityMarketsData: read_affine_heatrates,
    read_coal_prices, read_gas_prices, read_biomass_prices, read_isp_thermal_costs_parameters,
    read_isp_renewable_costs_parameters, read_isp_fixed_opex, read_isp_variable_opex
using .AustralianElectricityMarketsData: HiveConfiguration, AEMDB, aem_connect
using .AustralianElectricityMarketsData: read_hive, read_interconnectors, read_demand, read_energy_bids
using .AustralianElectricityMarketsData: _query
using .AustralianElectricityMarketsData: islocal, get_filesystem, _parse_hive_root

# `read_demand`/`read_interconnectors` are documented at their definition site inside the
# `AustralianElectricityMarketsData` submodule; `@doc` here binds that same docstring onto
# this module's own exported name, so `[`read_demand`](@ref)` etc. resolve from Documenter
# pages without duplicating the text (see the identical `nem_system`/`RegionalNetworkConfiguration`
# situation below).
@doc (@doc AustralianElectricityMarketsData.read_demand) read_demand
@doc (@doc AustralianElectricityMarketsData.read_interconnectors) read_interconnectors

# FCAS bid types (in addition to types.jl and offers.jl above)
include("fcas/bids.jl")

export NEMFCASReserve, ContingencyFCASReserve, RegulationFCASReserve, FCASResponseTime,
    FCASTrapezium, FCASOffer, FCASBid, NEMMarketBidCost,
    get_region, set_region!, get_response_time, set_response_time!,
    get_enablement_min, get_low_breakpoint, get_high_breakpoint, get_enablement_max,
    get_max_avail, get_ramp_up_rate, get_ramp_down_rate,
    get_reserve_name, get_offer_curve, get_trapezium,
    get_lower_slope_coeff, get_upper_slope_coeff, get_service

# Parsing data into models
include("network_models/region_model.jl")

# Exports the network models implemented
using .RegionModel: RegionalNetworkConfiguration, FCASNetworkConfiguration

# `nem_system`/`RegionalNetworkConfiguration`/`FCASNetworkConfiguration` are documented at
# their definition site inside the `RegionModel` submodule; `@doc` here binds that same
# docstring onto this module's own exported name, so `[`nem_system`](@ref)` etc. resolve
# from Documenter pages without duplicating the text (`nem_system(db, config)`'s own methods
# in `interface.jl`/`region_model.jl` are undocumented dispatch stubs).
@doc (@doc RegionModel.nem_system) nem_system
@doc (@doc RegionModel.RegionalNetworkConfiguration) RegionalNetworkConfiguration
@doc (@doc RegionModel.FCASNetworkConfiguration) FCASNetworkConfiguration

end
