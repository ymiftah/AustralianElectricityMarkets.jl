module AustralianElectricityMarkets

using PowerSystems
using DuckDB
using Dates
using DataFrames
using Chain
using Statistics
using AustralianElectricityMarketsCache
import AustralianElectricityMarketsCache: islocal, get_filesystem, _parse_hive_root
import TimeSeries: TimeArray, colnames
import PowerSystems as PSY
import InfrastructureSystems as IS

export HiveConfiguration, list_available_tables, aem_connect
export NetworkConfiguration, table_requirements, nem_system
export RegionalNetworkConfiguration, ConstrainedNetworkConfiguration
export set_mnsp_offers!, set_demand!, set_renewable_pv!, set_renewable_wind!,
    set_market_bids!, set_hydro_limits!
export get_storage_energy_max_avail
export set_fcas_bids!, set_fcas_scaling_inputs!
export set_nem_dispatch_limits!, set_nem_initial_conditions!, set_interconnector_flow_limits!, set_loss_demand_coefficients!
export get_initial_mw, get_energy_availability
export add_nem_constraints!, get_skipped_constraints, get_dropped_terms
export fcas_service_name
export FCAS_BID_TYPES, FCAS_CONTINGENCY_MARKETS, FCAS_REGULATION_MARKETS, BidType
export InterconnectorLossModel, loss_factor, interconnector_losses, loss_segments,
    loss_curve_vertex_values, attach_interconnector_losses!
export FCASTrapezium, FCASBid,
    get_enablement_min, get_low_breakpoint, get_high_breakpoint, get_enablement_max,
    get_max_avail, get_ramp_up_rate, get_ramp_down_rate, get_lower_slope_coeff, get_upper_slope_coeff,
    get_offer_curve, get_trapezium, scale_fcas_trapezium
export get_fcas_trapezium, get_fcas_offer_curve, get_fcas_bid, get_scaled_fcas_trapezium,
    get_fcas_agc_ramp_capability, get_fcas_agc_status
export ConstraintSense, ConstraintTerm, UnitTerm, InterconnectorTerm, RegionTerm, FCASRequirement,
    GenericConstraint,
    get_duid, get_bid_type, get_factor, get_interconnector, get_region, get_service, get_devices,
    get_sense, set_sense!, get_rhs, set_rhs!, get_constraint_weight, set_constraint_weight!,
    get_limit_type, get_source, get_effective_date, get_version_no, get_gencon_id,
    get_terms, set_terms!, get_fcas_requirements, set_fcas_requirements!, resolve_term_devices
export FCASService, add_fcas_services!, IntervalInputs, Readers

include("constants.jl")
include("types/bid_types.jl")
include("types/network_configuration.jl")
include("types/fcas.jl")
include("types/generic_constraints.jl")
include("types/interconnector_losses.jl")
include("types/interval_inputs.jl")

include("readers/Readers.jl")
using .Readers
using .Readers: _query, _current_regions, _intervention_where, _push_intervention!,
    _cast_double, _table_is_cached, _effective_date_bound, _fcas_req_union_sql,
    _expand_fcas_req_params, _require_fcas_float, _extract_fcas_bid,
    _refer_bids_to_reference_node!, _massage_bids, _extract_power_bids

for name in names(Readers)
    name === :Readers && continue
    @eval export $name
    @eval @doc (@doc Readers.$name) $name
end

include("accessors/bids.jl")
include("accessors/dispatch_limits.jl")
include("accessors/fcas.jl")
include("accessors/constraints.jl")
include("system/interface.jl")
include("system/demand.jl")
include("system/renewables.jl")
include("system/bids.jl")
include("system/dispatch_limits.jl")
include("system/fcas.jl")
include("system/mnsp.jl")
include("system/constraints.jl")
include("system/interconnectors.jl")
include("system/RegionModel.jl")

using .RegionModel: RegionalNetworkConfiguration, ConstrainedNetworkConfiguration

@doc (@doc AustralianElectricityMarketsCache.HiveConfiguration) HiveConfiguration
@doc (@doc AustralianElectricityMarketsCache.aem_connect) aem_connect
@doc (@doc AustralianElectricityMarketsCache.list_available_tables) list_available_tables
@doc (@doc RegionModel.nem_system) nem_system
@doc (@doc RegionModel.RegionalNetworkConfiguration) RegionalNetworkConfiguration
@doc (@doc RegionModel.ConstrainedNetworkConfiguration) ConstrainedNetworkConfiguration

end
