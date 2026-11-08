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
export RegionalNetworkConfiguration, NEMDEConfiguration
export set_mnsp_offers!, set_demand!, set_market_bids!, add_nem_constraints!, set_regional_availability!
export set_unit_conditions!, set_interconnector_flow_limits!
export get_skipped_constraints, get_dropped_terms,
    get_missing_constraint_intervals, get_defaulted_constraint_weights
export NEMBuildReport, get_build_report, set_build_report!
export MNSPDirection, InterconnectorKind, NEMInterconnectorRegistration, NEMInterconnectorLimits, NEMMNSPLink, NEMMNSPBid, NEMMNSPObservedState
export fcas_service_name, fcas_service, fcas_offer_series_name
export FCAS_BID_TYPES, FCAS_CONTINGENCY_MARKETS, FCAS_REGULATION_MARKETS, NEM_MARKETS, BidType
export InterconnectorLossModel, interconnector_loss_models, loss_factor, interconnector_losses, loss_segments,
    loss_curve_vertex_values, attach_interconnector_losses!
export FCASTrapezium,
    get_enablement_min, get_enablement_max,
    get_max_avail, get_ramp_up_rate, get_ramp_down_rate, get_lower_slope_coeff, get_upper_slope_coeff,
    scale_fcas_trapezium
export ConstraintSense, ConstraintTerm, UnitTerm, InterconnectorTerm, RegionTerm, FCASRequirement,
    GenericConstraint,
    get_duid, get_bid_type, get_factor, get_interconnector, get_region, get_service, get_devices,
    get_sense, get_constraint_weight, get_rhs, get_invoked,
    get_limit_type, get_source, get_gencon_id, get_effective_date, get_version_no,
    get_terms, get_fcas_requirements, resolve_term_devices
export FCASService, add_fcas_services!, Readers
export OfferSide, offer_side, side_suffix, NEM_SERIES, NEM_TELEMETRY_SERIES, NEM_OBSERVED_SERIES, NEM_INTERCONNECTOR_SERIES, NEM_MNSP_SERIES, NEM_CONSTRAINT_SERIES, energy_offer_series_name, energy_max_avail_series_name
export NEMOfferCost, NEMEnergyBid, NEMFCASBid, BidDirection, FastStartProfile, FCASTrapeziumPoints, bid_value, bid_series_name
export get_energy_bids, get_fcas_bids, get_direction, get_offer_curves, get_max_avail, get_roc_up, get_roc_down,
    get_fixed_load, get_minimum_load, get_fast_start_profile, get_daily_energy_constraint, get_normal_status,
    get_energy_limit, get_trapezium
export NEMThermalGen, NEMHydroGen, NEMRenewableGen, NEMStorage, NEMLoad
export NEMRegistration, NEMTelemetry, NEMObservedState, NEMStation, ScheduleType
export get_registration, get_telemetry, get_observed_state, set_registration!, set_telemetry!, set_observed_state!
export EnergyTieBreak, TIE_BREAK_SERVICE_NAME, TIE_BREAK_CVP_FACTOR
export MARKET_PRICE_CAP_BY_FINANCIAL_YEAR, DISPATCH_INTERVAL, constraint_cvp_factor
export UNIT_RAMP_CVP_FACTOR, INTERCONNECTOR_FLOW_CVP_FACTOR, ENERGY_OFFER_CVP_FACTOR, ENERGY_UIGF_CVP_FACTOR,
    ENERGY_MAX_AVAIL_CVP_FACTOR, AREA_BALANCE_CVP_FACTOR, INTERCONNECTOR_ZERO_CVP_FACTOR, FIXED_LOADING_CVP_FACTOR,
    MNSP_RAMP_CVP_FACTOR, MNSP_OFFER_CVP_FACTOR, MNSP_AVAILABILITY_CVP_FACTOR,
    FCAS_CAPACITY_CVP_FACTOR, FCAS_RAMPING_CVP_FACTOR, FCAS_MAXAVAIL_CVP_FACTOR, FCAS_BDU_RAMPING_CVP_FACTOR
export fcas_series_name, FCASBidDirection, fcas_bid_direction, single_series, remove_single_series!, replace_single_series!,
    nem_dispatch_devices, NEM_DISPATCH_DEVICE_TYPES, is_non_scheduled_load, is_commissioned, has_registration, is_semi_scheduled,
    energy_offer_sides

include("constants.jl")
include("utils.jl")
include("types/bid_types.jl")
include("network_configurations/NetworkConfigurations.jl")
using .NetworkConfigurations: NetworkConfiguration, RegionalNetworkConfiguration, NEMDEConfiguration
include("types/fcas.jl")
include("types/generic_constraints.jl")
include("types/interconnector_losses.jl")
include("types/tie_break.jl")

include("readers/Readers.jl")
using .Readers
using .Readers: _query, _table_is_cached, _require_cached, _massage_bids, _require_columns, _table_schema

for name in names(Readers)
    name === :Readers && continue
    @eval export $name
    @eval @doc (@doc Readers.$name) $name
end

include("accessors/series_names.jl")
include("types/nem_offer_cost.jl")
include("types/unit_data.jl")
include("types/network_data.jl")
include("types/build_report.jl")
include("types/nem_devices.jl")
include("accessors/device_flags.jl")
include("accessors/fcas.jl")
include("accessors/constraints.jl")
include("accessors/offers.jl")
include("accessors/bids.jl")
include("system/interface.jl")
include("system/demand.jl")
include("system/bids.jl")
include("system/dispatch_limits.jl")
include("system/unit_conditions.jl")
include("system/regional_availability.jl")
include("system/fcas.jl")
include("system/offers.jl")
include("system/mnsp.jl")
include("system/constraints.jl")
include("system/fixed_loads.jl")
include("system/interconnectors.jl")
include("system/penalties.jl")
include("system/RegionModel.jl")
include("system/replay_checks.jl")

using .RegionModel: nem_network
export nem_network

@doc (@doc AustralianElectricityMarketsCache.HiveConfiguration) HiveConfiguration
@doc (@doc AustralianElectricityMarketsCache.aem_connect) aem_connect
@doc (@doc NetworkConfigurations.RegionalNetworkConfiguration) RegionalNetworkConfiguration
@doc (@doc NetworkConfigurations.NEMDEConfiguration) NEMDEConfiguration
@doc (@doc RegionModel.nem_network) nem_network

include("precompile.jl")

end
