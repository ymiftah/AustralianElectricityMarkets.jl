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
