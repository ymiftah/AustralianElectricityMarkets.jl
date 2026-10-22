"""
    Each australian State (i.e. AEMO Region) is a combination of a load node and a generator node. The load nodes are connected.
    between states by interconnectors
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
- `include_solution`: whether to attach `"lhs"`/`"marginal_value"` solution series to each
  `GenericConstraint` (default `false`).
- `resolution`: the resolution for `GenericConstraint` time series; inferred from the data
  when `nothing` (default). FCAS bid series are unaffected and always use `Minute(5)`.
- `as_of`: the instant the unit and interconnector tables (loss factors, flow limits) are
  resolved as of. Defaults to `first(date_range)`, so a build no longer picks up a version that
  takes effect after the dates replayed; pass `nothing` for the latest cached version.
- `allow_empty_region_terms`: whether to proceed (with a warning) instead of throwing when a
  `RegionTerm`'s region has no matching device (default `false`).
- `unresolved_terms`: `:drop` (default) builds a generic constraint without any term whose
  component is absent from the system; `:skip` skips the whole constraint. See
  [`add_nem_constraints!`](@ref).
"""
struct ConstrainedNetworkConfiguration <: NetworkConfiguration end
