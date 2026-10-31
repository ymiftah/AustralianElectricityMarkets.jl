"""
    Each australian State (i.e. AEMO Region) is a combination of a load node and a generator node. The load nodes are connected.
    between states by interconnectors.
    Suitable for standard ED/UC studies with "standard" PSI templates.
"""
struct RegionalNetworkConfiguration <: NetworkConfiguration end

"""
    NEMDEConfiguration()

Constructs a constrained network with the demand, bids, dispatch inputs and loss data needed
for historical dispatch simulation. Pass `date_range` to [`nem_system`](@ref).

# Example
```julia
sys = nem_system(db, NEMDEConfiguration(); date_range = start:Minute(5):stop)
```
"""
struct NEMDEConfiguration <: NetworkConfiguration end
