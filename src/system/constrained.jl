"""
    table_requirements(::ConstrainedNetworkConfiguration)

`RegionalNetworkConfiguration`'s tables plus `:DISPATCHPRICE,
:DISPATCH_FCAS_REQ, :DISPATCHCONSTRAINT, :GENCONDATA, :SPDCONNECTIONPOINTCONSTRAINT,
:SPDREGIONCONSTRAINT, :SPDINTERCONNECTORCONSTRAINT`.
"""
AustralianElectricityMarkets.table_requirements(::ConstrainedNetworkConfiguration) = [
    table_requirements(RegionalNetworkConfiguration())...,
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
        intervention::Integer = 0,
        as_of = isnothing(date_range) ? nothing : first(date_range),
        kwargs...,
    )
    sys, _ = _constrained_system(db; date_range, intervention, as_of, kwargs...)
    return sys
end


function _constrained_system(
        db; date_range = nothing, intervention::Integer = 0,
        as_of = isnothing(date_range) ? nothing : first(date_range), kwargs...,
    )
    if isnothing(date_range)
        error("ConstrainedNetworkConfiguration requires a `date_range` keyword argument (e.g. `nem_system(db, ConstrainedNetworkConfiguration(); date_range = start:Minute(5):stop)`).")
    end
    sys, units = _regional_system(db; as_of, kwargs...)
    set_fcas_bids!(sys, db, date_range)
    invoked, fixed = AustralianElectricityMarkets._read_constraint_inputs(db, date_range; intervention)
    AustralianElectricityMarkets._add_nem_constraints!(sys, db, date_range, invoked, fixed; intervention)
    AustralianElectricityMarkets._set_nem_fixed_loads!(sys, fixed, date_range)
    add_fcas_services!(sys)
    attach_interconnector_losses!(sys, db, first(date_range))
    return sys, units
end


export ConstrainedNetworkConfiguration
