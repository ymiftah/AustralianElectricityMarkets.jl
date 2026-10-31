# Attaches the constraint build that `nem_system` runs, from the same cached inputs.
function build_constraints!(sys, db, date_range; intervention = 0)
    invoked, fixed = AustralianElectricityMarkets._read_constraint_inputs(db, date_range; intervention)
    return AustralianElectricityMarkets._add_nem_constraints!(sys, db, date_range, invoked, fixed; intervention)
end

function attach_fixed_loads!(sys, db, date_range)
    return AustralianElectricityMarkets._set_nem_fixed_loads!(sys, AustralianElectricityMarkets.read_fixed_loads(db, date_range), date_range)
end

function attach_demand!(sys, db, date_range; resolution = Minute(5))
    demand = AustralianElectricityMarkets.read_demand(db, date_range; resolution)
    return AustralianElectricityMarkets._set_demand!(sys, demand, date_range; resolution)
end

function attach_dispatch_limits!(sys, db, date_range)
    rows = AustralianElectricityMarkets.read_dispatch_limits(db, date_range; resolution = step(date_range))
    return AustralianElectricityMarkets._set_nem_dispatch_limits!(sys, rows, date_range)
end
