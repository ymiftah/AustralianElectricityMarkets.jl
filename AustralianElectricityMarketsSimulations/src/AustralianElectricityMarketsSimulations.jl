module AustralianElectricityMarketsSimulations

using AustralianElectricityMarkets
using AustralianElectricityMarketsData
using Chain
using DataFrames
using Dates
using DuckDB
using HydroPowerSimulations
using JuMP
using PowerSimulations
using PowerSystems
using Statistics

import PowerSimulations as PSI
import PowerSystems as PSY

# Reached through PSI/PSY rather than declared as direct dependencies, so they cannot version-skew
# from the pinned PowerSimulations.
const IS = PSY.IS
const PM = PSI.PM

include("errors.jl")
include("time_basis.jl")
include("constraint_formulations.jl")
include("nem_constraints.jl")
include("check/nem_constraints.jl")
include("nem_dispatch.jl")
include("nem_dispatch_storage.jl")
include("devices/interconnector_losses.jl")
include("check/interconnector_losses.jl")
include("psi_compat.jl")
include("fcas_market.jl")
include("check/fcas.jl")
include("replication/inputs.jl")
include("replication/preprocessing.jl")

export DISPATCH_INTERVAL_HOURS, DISPATCH_INTERVAL, interval_hours, interval_cost_coefficient
export IntervalInputs, read_interval_inputs
export energy_bounds
export scale_trapezium
export AbstractNEMConstraintFormulation, NEMConstraintLHS, NEMConstraintLimit,
    NEMConstraintRHSParameter, LinearFactorLimit, FCASMarket
export GenericConstraintSlackUp, GenericConstraintSlackDown, MARKET_PRICE_CAP_BY_FINANCIAL_YEAR
export FCASCapacityVariable, FCASSideCapacityVariable, FCASUnitRegulationTarget,
    FCASJointCapacityLHS, FCASJointCapacityConstraint, FCASBDURampingConstraint,
    FCASJointRampingConstraint
export filter_buildable_generic_constraints
export check_fcas_services
export AbstractNEMDispatch, NEMReplayDispatch, NEMLookaheadDispatch,
    RampUpRateTimeSeriesParameter, RampDownRateTimeSeriesParameter,
    InitialPowerTimeSeriesParameter
export nem_dispatch_participants, set_nem_dispatch_models!
export NEMInterconnectorLoss, InterconnectorLossVariable, InterconnectorLossSegmentVariable,
    InterconnectorFlowSegmentConstraint, InterconnectorLossDefinitionConstraint
export interconnector_loss_gaps, check_interconnector_loss_segments

end
