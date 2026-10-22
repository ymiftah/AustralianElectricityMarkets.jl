"""
    Readers

Read cached NEMWEB market data and bundled ISP inputs. Public reader functions are
also re-exported from `AustralianElectricityMarkets`.
"""
module Readers

using CSV
using Chain
using DataFrames
using Dates
using DuckDB
using PowerSystems
using Statistics: median, mean
using AustralianElectricityMarketsCache
import AustralianElectricityMarketsCache: _parse_hive_root
import ..AustralianElectricityMarkets: BidType, FCAS_BID_TYPES,
    FCAS_CONTINGENCY_MARKETS, FCAS_REGULATION_MARKETS, FCASTrapezium, FCASBid,
    ConstraintSense, InterconnectorLossModel, IntervalInputs,
    AEMO_PM_MAPPING, AEMO_FUEL_MAPPING, _validate_fcas_trapezium

export read_hive, read_units, read_demand, read_energy_bids, read_fixed_loads, read_bids, read_loss_factors
export read_fcas_bids, read_fcas_requirements, read_fcas_prices, read_fcas_dispatch,
    read_fcas_scaling_inputs
export read_invoked_constraints, read_constraint_definitions, read_constraint_terms,
    read_constraint_fcas_requirements
export read_interconnectors, read_interconnector_limits,
    read_interconnector_loss_breakpoints, read_interconnector_demand_coefficients,
    read_interconnector_loss_parameters, interconnector_loss_models
export read_mnsp_offers, read_mnsp_links
export read_dispatch_limits, read_energy_limits, read_uigf, read_prices
export read_interval_inputs, read_published_interval, read_uigf_as_dict
export read_affine_heatrates, read_coal_prices, read_gas_prices, read_biomass_prices,
    read_isp_thermal_costs_parameters, read_isp_renewable_costs_parameters,
    read_isp_fixed_opex, read_isp_variable_opex

include("hive.jl")
include("query_helpers.jl")
include("units.jl")
include("demand.jl")
include("bids.jl")
include("energy_limits.jl")
include("constraints.jl")
include("fcas.jl")
include("interconnectors.jl")
include("mnsp.jl")
include("dispatch.jl")
include("prices.jl")
include("intervals.jl")
include("isp.jl")

end
