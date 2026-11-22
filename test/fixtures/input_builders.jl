# Attaches the constraint build that `nem_system` runs, from the same cached inputs.
function build_constraints!(sys, db, date_range; intervention = 0)
    return add_nem_constraints!(sys, db, date_range; intervention)
end

function attach_demand!(sys, db, date_range; resolution = Minute(5))
    demand = AustralianElectricityMarkets.read_demand(db, date_range; resolution)
    return AustralianElectricityMarkets._set_demand!(sys, demand, date_range; resolution)
end

function attach_dispatch_limits!(sys, db, date_range)
    return set_unit_conditions!(sys, db, date_range)
end

# The network, bids, NEM constraints and interconnector losses over `date_range`, without the
# unit conditions and dispatch limits that `nem_system` adds. Returns `(sys, units)`.
function constrained_system(db; date_range, intervention::Integer = 0)
    sys, units = nem_network(db; date_range = date_range)
    set_market_bids!(sys, db, date_range)
    add_nem_constraints!(sys, db, date_range; intervention)
    attach_interconnector_losses!(sys, db, first(date_range))
    return sys, units
end
