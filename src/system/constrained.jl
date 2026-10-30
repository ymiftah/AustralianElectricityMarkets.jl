"""
    _constrained_system(db; date_range, intervention = 0, as_of = first(date_range), through = last(date_range) - step(date_range), kwargs...) -> (sys, units)

The cost-free network (`_nem_network`) with FCAS bids, FCAS services, NEM generic constraints
and interconnector losses over `date_range`, without energy or FCAS price bids. It reads no ISP
operating costs. `units` is every unit registered in `[first, last]` of `date_range` (see
[`read_units`](@ref)). Used by [`NEMDEConfiguration`](@ref), which adds the energy and FCAS price
bids on top.
"""
function _constrained_system(
        db; date_range = nothing, intervention::Integer = 0,
        as_of = isnothing(date_range) ? nothing : first(date_range),
        through = isnothing(date_range) ? nothing : last(date_range) - step(date_range), kwargs...,
    )
    if isnothing(date_range)
        error("the constrained system requires a `date_range` keyword argument.")
    end
    sys, units, _ = _nem_network(db; as_of, through, kwargs...)
    set_fcas_bids!(sys, db, date_range)
    invoked, fixed = AustralianElectricityMarkets._read_constraint_inputs(db, date_range; intervention)
    AustralianElectricityMarkets._add_nem_constraints!(sys, db, date_range, invoked, fixed; intervention)
    AustralianElectricityMarkets._set_nem_fixed_loads!(sys, fixed, date_range)
    attach_interconnector_losses!(sys, db, first(date_range))
    return sys, units
end
