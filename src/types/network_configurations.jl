"""
    Each australian State (i.e. AEMO Region) is a combination of a load node and a generator node. The load nodes are connected.
    between states by interconnectors.
    Suitable for standard ED/UC studies with "standard" PSI templates.
"""
struct RegionalNetworkConfiguration <: NetworkConfiguration end

"""
    Like `RegionalNetworkConfiguration`, but also pulls the tables needed for NEM generic
    constraints — FCAS requirements and network limits alike (see `GenericConstraint`) — and
    builds them into the resulting system via `set_fcas_bids!`/`add_nem_constraints!`/
    `add_fcas_services!`/`attach_interconnector_losses!`. Kept separate from
    `RegionalNetworkConfiguration` so energy-only users aren't forced to pull the extra tables.

# Arguments
- `date_range`: required, the date range to build FCAS bids and constraints over.
- `intervention`: which AEMO intervention run to read (default `0`).
- `as_of`: the instant the unit and interconnector tables (loss factors, flow limits) are
  resolved as of. Defaults to `first(date_range)`, so a build no longer picks up a version that
  takes effect after the dates replayed; pass `nothing` for the latest cached version.
"""
struct ConstrainedNetworkConfiguration <: NetworkConfiguration end


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
