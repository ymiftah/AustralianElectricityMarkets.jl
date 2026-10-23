module AustralianElectricityMarkets

using PowerSystems
using DuckDB
using Dates
using DataFrames
using Chain
using Statistics
using AustralianElectricityMarketsCache
import AustralianElectricityMarketsCache: _parse_hive_root
import TimeSeries: TimeArray, colnames, timestamp
import PowerSystems as PSY
import InfrastructureSystems as IS

export HiveConfiguration, aem_connect
export NetworkConfiguration, table_requirements, nem_system
export RegionalNetworkConfiguration, ConstrainedNetworkConfiguration, ReplayNetworkConfiguration
export set_mnsp_offers!, set_demand!, set_market_bids!
export get_storage_energy_max_avail
export set_fcas_bids!, set_fcas_scaling_inputs!
export set_nem_dispatch_limits!, set_interconnector_flow_limits!, set_loss_demand_coefficients!
export get_initial_mw, get_energy_availability
export set_nem_energy_limits!
export set_nem_fixed_loads!
export add_nem_constraints!, get_skipped_constraints, get_dropped_terms,
    get_missing_constraint_intervals, get_defaulted_constraint_weights
export fcas_service_name
export FCAS_BID_TYPES, FCAS_CONTINGENCY_MARKETS, FCAS_REGULATION_MARKETS, BidType
export InterconnectorLossModel, interconnector_loss_models, loss_factor, interconnector_losses, loss_segments,
    loss_curve_vertex_values, attach_interconnector_losses!
export FCASTrapezium,
    get_enablement_min, get_low_breakpoint, get_high_breakpoint, get_enablement_max,
    get_max_avail, get_ramp_up_rate, get_ramp_down_rate, get_lower_slope_coeff, get_upper_slope_coeff,
    scale_fcas_trapezium
export get_scaled_fcas_trapezium,
    get_fcas_agc_ramp_capability, get_fcas_agc_status
export ConstraintSense, ConstraintTerm, UnitTerm, InterconnectorTerm, RegionTerm, FCASRequirement,
    GenericConstraint,
    get_duid, get_bid_type, get_factor, get_interconnector, get_region, get_service, get_devices,
    get_sense, get_rhs, get_constraint_weight, set_constraint_weight!,
    get_limit_type, get_source, get_gencon_id,
    get_terms, get_fcas_requirements, resolve_term_devices
export FCASService, add_fcas_services!, Readers
export OfferSide, offer_side, side_suffix, NEM_SERIES, energy_max_avail_series_name
export NEMEnergyOffer, get_energy_offer, NEMFCASOffer, get_fcas_offer
export fcas_series_name, mnsp_series_name, FCASBidDirection, fcas_bid_direction, single_series, remove_single_series!, replace_single_series!,
    nem_dispatch_devices, is_non_scheduled_load, is_commissioned, has_schedule_classification, is_semi_scheduled,
    energy_offer_sides

include("constants.jl")
include("types/bid_types.jl")
include("types/network_configuration.jl")
include("types/fcas.jl")
include("types/generic_constraints.jl")
include("types/interconnector_losses.jl")

include("readers/Readers.jl")
using .Readers
using .Readers: _query, _table_is_cached, _require_cached, _massage_bids

for name in names(Readers)
    name === :Readers && continue
    @eval export $name
    @eval @doc (@doc Readers.$name) $name
end

include("accessors/series_names.jl")
include("accessors/device_flags.jl")
include("accessors/bids.jl")
include("accessors/dispatch_limits.jl")
include("accessors/fcas.jl")
include("accessors/constraints.jl")
include("accessors/offers.jl")
include("system/interface.jl")
include("system/demand.jl")
include("system/bids.jl")
include("system/dispatch_limits.jl")
include("system/energy_limits.jl")
include("system/fcas.jl")
include("system/mnsp.jl")
include("system/constraints.jl")
include("system/fixed_loads.jl")
include("system/interconnectors.jl")
include("system/RegionModel.jl")

using .RegionModel: RegionalNetworkConfiguration, ConstrainedNetworkConfiguration, ReplayNetworkConfiguration

@doc (@doc AustralianElectricityMarketsCache.HiveConfiguration) HiveConfiguration
@doc (@doc AustralianElectricityMarketsCache.aem_connect) aem_connect
@doc (@doc RegionModel.nem_system) nem_system
@doc (@doc RegionModel.RegionalNetworkConfiguration) RegionalNetworkConfiguration
@doc (@doc RegionModel.ConstrainedNetworkConfiguration) ConstrainedNetworkConfiguration
@doc (@doc RegionModel.ReplayNetworkConfiguration) ReplayNetworkConfiguration

end
