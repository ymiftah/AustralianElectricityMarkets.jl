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
# constraint_formulations.jl defines AbstractNEMConstraintFormulation; nem_constraints.jl's
# TermConstraint subtypes it, so it must be included first.
include("services/constraint_formulations.jl")
include("services/nem_constraints.jl")
include("psi_compat.jl")
include("replication/inputs.jl")
include("replication/preprocessing.jl")

export IntervalInputs, read_interval_inputs
export energy_bounds
export EffectiveTrapezium, scale_trapezium, lower_slope_coeff, upper_slope_coeff
export AbstractNEMConstraintFormulation
export NEMConstraintLHS, NEMConstraintLimit, NEMConstraintRHSParameter, TermConstraint

end
