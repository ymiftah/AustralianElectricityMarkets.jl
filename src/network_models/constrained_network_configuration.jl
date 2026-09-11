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
- `allow_empty_region_terms`: whether to proceed (with a warning) instead of throwing when a
  `RegionTerm`'s region has no matching device (default `false`).
"""
struct ConstrainedNetworkConfiguration <: NetworkConfiguration end

"""
    table_requirements(::ConstrainedNetworkConfiguration)

`RegionalNetworkConfiguration`'s tables plus `:DISPATCHLOAD, :DISPATCHPRICE,
:DISPATCH_FCAS_REQ, :DISPATCHCONSTRAINT, :GENCONDATA, :SPDCONNECTIONPOINTCONSTRAINT,
:SPDREGIONCONSTRAINT, :SPDINTERCONNECTORCONSTRAINT`.
"""
AustralianElectricityMarkets.table_requirements(::ConstrainedNetworkConfiguration) = [
    table_requirements(RegionalNetworkConfiguration())...,
    :DISPATCHLOAD,
    :DISPATCHPRICE,
    # Both generations of the dispatch FCAS requirement table: DISPATCH_FCAS_REQ covers up
    # to the 2025-05 archive month, DISPATCH_FCAS_REQ_CONSTRAINT from 2025-06 on. A cache
    # holding only one still builds - readers union whichever are present.
    :DISPATCH_FCAS_REQ,
    :DISPATCH_FCAS_REQ_CONSTRAINT,
    :DISPATCHCONSTRAINT,
    :GENCONDATA,
    :SPDCONNECTIONPOINTCONSTRAINT,
    :SPDREGIONCONSTRAINT,
    :SPDINTERCONNECTORCONSTRAINT,
]

# Explicit kwargs (not folded into kwargs...) so none of them leak into System(base_power;
# kwargs...), which rejects any kwarg it doesn't recognize.
function AustralianElectricityMarkets.nem_system(
        db, ::ConstrainedNetworkConfiguration; date_range = nothing,
        intervention::Integer = 0, include_solution::Bool = false,
        resolution::Union{Nothing, Dates.Period} = nothing,
        allow_empty_region_terms::Bool = false,
        kwargs...,
    )
    if isnothing(date_range)
        error("ConstrainedNetworkConfiguration requires a `date_range` keyword argument (e.g. `nem_system(db, ConstrainedNetworkConfiguration(); date_range = start:Minute(5):stop)`).")
    end
    sys = nem_system(db; kwargs...)
    set_fcas_bids!(sys, db, date_range)
    add_nem_constraints!(
        sys, db, date_range; intervention = intervention, include_solution = include_solution,
        resolution = resolution, allow_empty_region_terms = allow_empty_region_terms,
    )
    add_fcas_services!(sys)
    attach_interconnector_losses!(sys, db, first(date_range))
    return sys
end

export ConstrainedNetworkConfiguration
