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

# Reached through PSI/PSY rather than taken as direct dependencies: this package is already
# pinned to one PowerSimulations version (see psi_compat.jl), so these cannot version-skew from
# it, and adding them as deps would be a second place to keep in step.
const IS = PSY.IS
const PM = PSI.PM

include("errors.jl")
include("time_basis.jl")
include("constraint_formulations.jl")
include("nem_dispatch.jl")
include("psi_compat.jl")
include("replication/inputs.jl")
include("replication/preprocessing.jl")

export DISPATCH_INTERVAL_HOURS, interval_cost_coefficient
export IntervalInputs, read_interval_inputs
export energy_bounds
export EffectiveTrapezium, scale_trapezium, lower_slope_coeff, upper_slope_coeff
export AbstractNEMConstraintFormulation, NEMConstraintLHS, NEMConstraintLimit,
    NEMConstraintRHSParameter, LinearFactorLimit, FCASMarket
export RampBase, MeteredRampBase, ChainedRampBase, NEMDispatch,
    NEMReplayDispatch, NEMLookaheadDispatch,
    RampUpRateTimeSeriesParameter, RampDownRateTimeSeriesParameter,
    InitialPowerTimeSeriesParameter
export nem_dispatch_participants, set_nem_dispatch_models!

end
