# Shared toy market for the NEMDE walkthrough pages (`nemde_jump`, `nemde_psi`, `nemde_aem`).
# Plain Julia: no PowerSystems, PowerSimulations or JuMP. Quantities are in MW, prices in $/MWh
# (energy) or $/MW/h (FCAS), ramp rates in MW/h as in NEMWEB.

using Dates

const T0 = DateTime(2025, 1, 1, 12, 0)   # the dispatch interval being cleared
const RESOLUTION = Minute(5)
const INTERVAL_H = 5 / 60                # interval length in hours
const BASE_POWER = 100.0                 # MVA, the PowerSystems base
const MARKET_PRICE_CAP = 17_500.0        # $/MWh, financial year 2024-25

#>> types
"One price band of an offer: up to `quantity` MW at `price`."
struct Bid
    quantity::Float64
    price::Float64
end

"The FCAS trapezium: enablement limits, break points and maximum availability, all in MW."
struct Trapezium
    enablement_min::Float64
    low_breakpoint::Float64
    high_breakpoint::Float64
    enablement_max::Float64
    max_avail::Float64
end

"A unit's offer for one FCAS service: its trapezium and price bands."
struct FCASOffer
    trapezium::Trapezium
    bids::Vector{Bid}
end

"""
A scheduled (`uigf === nothing`) or semi-scheduled (`uigf` set) unit with its energy offer,
`initial_mw` at the start of the interval and ramp rates in MW/h.
"""
struct Unit
    name::Symbol
    region::String
    capacity::Float64
    max_avail::Float64
    uigf::Union{Nothing, Float64}
    initial_mw::Float64
    ramp_up_mwh::Float64
    ramp_down_mwh::Float64
    bids::Vector{Bid}
    fcas::Union{Nothing, FCASOffer}
end

"""
A regional interconnector. Flow is positive from `from` to `to` and bounded by `max_flow` in
both directions; losses are `loss_coefficient / 2 * flow^2`, linearised on `breakpoints`, and a
`from_loss_share` fraction of them is charged to the `from` region.
"""
struct Interconnector
    name::String
    from::String
    to::String
    max_flow::Float64
    loss_coefficient::Float64
    from_loss_share::Float64
    breakpoints::Vector{Float64}
end

"One linear term of a generic constraint: `factor` times a unit's energy, a unit's RAISE6SEC or the interconnector flow."
struct Term
    kind::Symbol
    id::Union{Symbol, String}
    factor::Float64
end

"""
A generic constraint `sum(terms) <sense> rhs`. `weight` is its constraint violation penalty
factor: violating it costs `weight * MARKET_PRICE_CAP` per MW per hour.
"""
struct LinearConstraint
    name::String
    sense::Symbol
    rhs::Float64
    weight::Float64
    terms::Vector{Term}
end

struct Market
    regions::Vector{String}
    units::Vector{Unit}
    demand::Dict{String, Float64}
    interconnector::Interconnector
    constraints::Vector{LinearConstraint}
end

#<< types

# ## Accessors, so that the model reads as `bid(unit, j)` rather than `unit.bids[j]`.

#>> accessors
unit_name(unit::Unit) = unit.name
region(unit::Unit) = unit.region
bids(unit::Unit) = unit.bids
n_bids(unit::Unit) = length(unit.bids)
bid(unit::Unit, j) = unit.bids[j]
quantity(b::Bid) = b.quantity
price(b::Bid) = b.price
initial_mw(unit::Unit) = unit.initial_mw
is_semi_scheduled(unit::Unit) = !isnothing(unit.uigf)

"MW the unit may be dispatched to: `MAXAVAIL`, capped by the `UIGF` of a semi-scheduled unit."
availability(unit::Unit) = isnothing(unit.uigf) ? unit.max_avail : min(unit.max_avail, unit.uigf)
"MW the unit can add / shed within one interval from its initial MW."
ramp_up(unit::Unit) = unit.ramp_up_mwh * INTERVAL_H
ramp_down(unit::Unit) = unit.ramp_down_mwh * INTERVAL_H

has_fcas(unit::Unit) = !isnothing(unit.fcas)
fcas_bids(unit::Unit) = unit.fcas.bids
n_fcas_bids(unit::Unit) = length(unit.fcas.bids)
fcas_bid(unit::Unit, j) = unit.fcas.bids[j]
trapezium(unit::Unit) = unit.fcas.trapezium
max_avail(t::Trapezium) = t.max_avail
upper_slope(t::Trapezium) = (t.enablement_max - t.high_breakpoint) / t.max_avail
lower_slope(t::Trapezium) = (t.low_breakpoint - t.enablement_min) / t.max_avail

units_in(market::Market, region) = [u for u in market.units if u.region == region]
fcas_units(market::Market) = [u for u in market.units if has_fcas(u)]
find_unit(market::Market, id::Symbol) = only(u for u in market.units if u.name == id)
region_demand(market::Market, region) = market.demand[region]

"The interconnector's loss curve linearised on its breakpoints, as `(from_mw, to_mw, slope)` per segment."
loss_at(ic::Interconnector, flow) = ic.loss_coefficient / 2 * flow^2
"The loss at zero flow of the chord that brackets it; subtracting it makes the linearised curve lose nothing at zero flow."
function zero_flow_chord_loss(ic::Interconnector)
    bp = ic.breakpoints
    i = findfirst(i -> bp[i] < 0 < bp[i + 1], 1:(length(bp) - 1))
    isnothing(i) && return 0.0
    return -ic.loss_coefficient * bp[i] * bp[i + 1] / 2
end
function linearised_losses(ic::Interconnector)
    bp = ic.breakpoints
    return [
        (from_mw = a, to_mw = b, slope = (loss_at(ic, b) - loss_at(ic, a)) / (b - a))
            for (a, b) in zip(bp[1:(end - 1)], bp[2:end])
    ]
end

#<< accessors

# ## The market

#>> market
market = Market(
    ["NSW1", "VIC1"],
    [
        Unit(
            :COAL1, "NSW1", 600.0, 600.0, nothing, 420.0, 600.0, 600.0,
            [Bid(200, 25), Bid(150, 35), Bid(150, 55), Bid(100, 90)],
            FCASOffer(Trapezium(150, 200, 350, 450, 60), [Bid(20, 2), Bid(40, 8)]),
        ),
        Unit(
            :WIND1, "NSW1", 200.0, 200.0, 150.0, 140.0, 1200.0, 1200.0,
            [Bid(200, 0)], nothing,
        ),
        Unit(
            :GAS1, "VIC1", 400.0, 400.0, nothing, 180.0, 1800.0, 1800.0,
            [Bid(100, 70), Bid(150, 110), Bid(150, 250)],
            FCASOffer(Trapezium(50, 100, 300, 400, 40), [Bid(40, 12)]),
        ),
    ],
    Dict("NSW1" => 450.0, "VIC1" => 380.0),
    Interconnector("NSW1-VIC1", "NSW1", "VIC1", 100.0, 0.0006, 0.5, [-100.0, -60.0, -20.0, 20.0, 60.0, 100.0]),
    [
        LinearConstraint("N_COAL_LIMIT", :LE, 375.0, 5.0, [Term(:energy, :COAL1, 1.0)]),
        LinearConstraint("F_NSW_R6", :GE, 40.0, 1.0, [Term(:raise6, :COAL1, 1.0)]),
        LinearConstraint("F_VIC_R6", :GE, 30.0, 1.0, [Term(:raise6, :GAS1, 1.0)]),
    ],
);
#<< market

"The same market with a lossless interconnector and no generic constraints: the part of NEMDE a stock PSI formulation can express."
function energy_market(market::Market)
    ic = market.interconnector
    lossless = Interconnector(ic.name, ic.from, ic.to, ic.max_flow, 0.0, ic.from_loss_share, ic.breakpoints)
    return Market(market.regions, market.units, market.demand, lossless, LinearConstraint[])
end
