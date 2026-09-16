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

include("errors.jl")
include("time_basis.jl")
include("constraint_formulations.jl")
include("nem_constraints.jl")
include("buildability.jl")
include("psi_compat.jl")
include("replication/inputs.jl")
include("replication/preprocessing.jl")

export DISPATCH_INTERVAL_HOURS, interval_cost_coefficient
export IntervalInputs, read_interval_inputs
export energy_bounds
export EffectiveTrapezium, scale_trapezium, lower_slope_coeff, upper_slope_coeff
export AbstractNEMConstraintFormulation, NEMConstraintLHS, NEMConstraintLimit,
    NEMConstraintRHSParameter, LinearFactorLimit, FCASMarket
export filter_buildable_generic_constraints

end
