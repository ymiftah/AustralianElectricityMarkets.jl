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
# nem_constraints.jl defines GenericConstraint's PSI.Service formulation types; psi_compat.jl's
# `_modify_device_model!` no-op dispatches on them, so it must be included after.
include("services/nem_constraints.jl")
include("psi_compat.jl")
include("replication/inputs.jl")
include("replication/preprocessing.jl")

export IntervalInputs, read_interval_inputs
export energy_bounds
export EffectiveTrapezium, scale_trapezium, lower_slope_coeff, upper_slope_coeff
export NEMConstraintLHS, NEMConstraintLimit, NEMConstraintRHSParameter, NEMGenericConstraint

end
