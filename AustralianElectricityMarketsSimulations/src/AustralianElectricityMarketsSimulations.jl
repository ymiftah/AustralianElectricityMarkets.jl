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
include("psi_compat.jl")
include("fcas_market.jl")
include("check/fcas.jl")
include("replication/inputs.jl")
include("replication/preprocessing.jl")

export DISPATCH_INTERVAL_HOURS, interval_cost_coefficient
export IntervalInputs, read_interval_inputs
export energy_bounds
export scale_trapezium
export AbstractNEMConstraintFormulation, NEMConstraintLHS, NEMConstraintLimit,
    NEMConstraintRHSParameter, LinearFactorLimit, FCASMarket
export FCASCapacityVariable, FCASSideCapacityVariable, FCASUnitRegulationTarget,
    FCASJointCapacityLHS, FCASJointCapacityConstraint, FCASBDURampingConstraint
export filter_buildable_generic_constraints
export check_fcas_services
export AbstractNEMDispatch, NEMReplayDispatch, NEMLookaheadDispatch,
    RampUpRateTimeSeriesParameter, RampDownRateTimeSeriesParameter,
    InitialPowerTimeSeriesParameter
export nem_dispatch_participants, set_nem_dispatch_models!

end
