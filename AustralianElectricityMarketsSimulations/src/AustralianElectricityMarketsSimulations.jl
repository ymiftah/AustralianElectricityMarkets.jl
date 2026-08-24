module AustralianElectricityMarketsSimulations

using AustralianElectricityMarkets
using AustralianElectricityMarketsData
using Chain
using DataFrames
using Dates
using DuckDB
using PowerSystems
using Statistics

import PowerSystems as PSY

include("errors.jl")
include("replication/inputs.jl")
include("replication/preprocessing.jl")

export IntervalInputs, read_interval_inputs
export energy_bounds
export EffectiveTrapezium, scale_trapezium, lower_slope_coeff, upper_slope_coeff

end
