module RegionModel

using ..AustralianElectricityMarkets
using DataFrames, Chain, Statistics
using PowerSystems
import PowerSystems as PSY
using Dates

export nem_system, set_demand!

include("../types/network_configurations.jl")
include("components.jl")
include("network.jl")
include("regional.jl")
include("constrained.jl")
include("replay.jl")

end
