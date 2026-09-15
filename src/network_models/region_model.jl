module RegionModel

using ..AustralianElectricityMarkets
using DataFrames, Chain, Statistics
using PowerSystems
using Dates

export nem_system, set_demand!, set_renewable_pv!, set_renewable_wind!

include("common.jl")
include("regional_network_configuration.jl")
include("constrained_network_configuration.jl")

end
