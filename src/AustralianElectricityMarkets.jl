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
export RegionalNetworkConfiguration, ConstrainedNetworkConfiguration

export read_hive
export read_interconnectors, read_units, read_demand, read_bids, read_energy_bids
export read_affine_heatrates,
    read_coal_prices, read_gas_prices, read_biomass_prices, read_isp_thermal_costs_parameters,
    read_isp_renewable_costs_parameters,
    read_isp_fixed_opex, read_isp_variable_opex
export set_demand!, set_renewable_pv!, set_renewable_wind!, set_market_bids!, set_hydro_limits!
export read_fcas_bids, set_fcas_bids!, read_fcas_requirements,
    read_fcas_prices, read_fcas_dispatch, read_prices, read_uigf
export read_invoked_constraints, read_constraint_definitions, read_constraint_terms,
    read_constraint_fcas_requirements, add_nem_constraints!
export FCAS_BID_TYPES, FCAS_CONTINGENCY_MARKETS, FCAS_REGULATION_MARKETS
export BidType


# Write your package code here.
include("constants.jl")
include("units.jl")
include("network_models/interface.jl")

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

# Modules
include("parser.jl")

# FCAS (Frequency Control Ancillary Services) and NEM generic constraint types.
#
# Defined directly in this top-level module, NOT a nested submodule: confirmed directly
# that PSY/IS's component-type lookup on JSON deserialize (`InfrastructureSystems.get_module`,
# via `Base.root_module`) only resolves top-level package names, not dotted submodule paths.
#
# Included after parser.jl: FCASBid.service::BidType and UnitTerm/RegionTerm's
# bid_type::BidType fields both need BidType (defined in parser.jl) in scope at
# struct-definition time.
include("fcas/bids.jl")
include("constraints/terms.jl")
include("constraints/generic_constraint.jl")
include("constraints/read.jl")
include("constraints/resolve.jl")
include("constraints/build.jl")

export FCASTrapezium, FCASBid,
    get_enablement_min, get_low_breakpoint, get_high_breakpoint, get_enablement_max,
    get_max_avail, get_ramp_up_rate, get_ramp_down_rate, get_lower_slope_coeff, get_upper_slope_coeff,
    get_offer_curve, get_trapezium
export ConstraintSense, ConstraintTerm, UnitTerm, InterconnectorTerm, RegionTerm, FCASRequirement,
    GenericConstraint,
    get_duid, get_bid_type, get_factor, get_interconnector, get_region, get_service, get_devices,
    get_sense, set_sense!, get_rhs, set_rhs!, get_constraint_weight, set_constraint_weight!,
    get_limit_type, get_source, get_effective_date, get_version_no, get_gencon_id,
    get_terms, set_terms!, get_fcas_requirements, set_fcas_requirements!,
    resolve_term_devices

# Parsing data into models
include("network_models/region_model.jl")

# Exports the network models implemented
using .RegionModel: RegionalNetworkConfiguration, ConstrainedNetworkConfiguration

# `nem_system`/`RegionalNetworkConfiguration`/`ConstrainedNetworkConfiguration` are documented
# at their definition site inside the `RegionModel` submodule; `@doc` here binds that same
# docstring onto this module's own exported name, so `[`nem_system`](@ref)` etc. resolve
# from Documenter pages without duplicating the text (`nem_system(db, config)`'s own methods
# in `interface.jl`/`region_model.jl` are undocumented dispatch stubs).
@doc (@doc RegionModel.nem_system) nem_system
@doc (@doc RegionModel.RegionalNetworkConfiguration) RegionalNetworkConfiguration
@doc (@doc RegionModel.ConstrainedNetworkConfiguration) ConstrainedNetworkConfiguration

end
