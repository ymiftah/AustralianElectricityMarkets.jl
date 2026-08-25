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
include("psi_compat.jl")
include("replication/inputs.jl")
include("replication/preprocessing.jl")
include("replication/tiers.jl")

export IntervalInputs, read_interval_inputs
export energy_bounds
export EffectiveTrapezium, scale_trapezium, lower_slope_coeff, upper_slope_coeff
export FidelityTier, T0CopperPlate, T1Interconnected, tier_name
export IntervalResult, build_template, solve_interval

end
