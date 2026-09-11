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
include("per_unit.jl")
include("constraint_formulations.jl")
include("psi_compat.jl")
include("replication/inputs.jl")
include("replication/preprocessing.jl")

export IntervalInputs, read_interval_inputs
export energy_bounds
export EffectiveTrapezium, scale_trapezium, lower_slope_coeff, upper_slope_coeff
export AbstractNEMConstraintFormulation, NEMConstraintLHS, NEMConstraintLimit,
    NEMConstraintRHSParameter, LinearFactorLimit, FCASMarket
export DISPATCH_INTERVAL_HOURS
export mw_to_pu, pu_to_mw, price_to_pu_coefficient, dimensionless_factor

end
