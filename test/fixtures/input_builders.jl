# Attaches the constraint build that `nem_system` runs, from the same cached inputs.
function build_constraints!(sys, db, date_range; intervention = 0)
    return add_nem_constraints!(sys, db, date_range; intervention)
end

function attach_demand!(sys, db, date_range; resolution = Minute(5))
    demand = AustralianElectricityMarkets.read_demand(db, date_range; resolution)
    return AustralianElectricityMarkets.set_demand!(sys, demand, date_range; resolution)
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

# The offer curve of one row from its band `prices` and `widths`, as `set_market_bids!` builds it.
function offer_curve(prices, widths, direction)
    column(values) = Tuple([v] for v in values)
    return only(AustralianElectricityMarkets._offer_curves([true], column(prices), column(widths), direction == "LOAD"))
end

# The ten band prices and availabilities of an offer row.
band_vectors(row) = (
    prices = [row[c] for c in AustralianElectricityMarkets.PRICE_BAND_COLUMNS],
    widths = [row[c] for c in AustralianElectricityMarkets.BAND_AVAIL_COLUMNS],
)
