# Shared toy market for the NEMDE walkthrough pages (`nemde_jump`, `nemde_psi`, `nemde_aem`).
# The market is defined once as plain data (`market`) and built into a PowerSystems `System` by
# `toy_system`. The JuMP models read the energy data back from that `System`. Quantities are in MW,
# prices in $/MWh (energy) or $/MW/h (FCAS), ramp rates in MW/h as in NEMWEB.

using Dates
import PowerSystems as PSY
using AustralianElectricityMarkets: attach_nem_unit_data!

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
A scheduled (`uigf === nothing`) or semi-scheduled (`uigf` set) unit. `max_avail` and `uigf` cap its
dispatch, `initial_mw` is its output at the start of the interval and the ramp rates are in MW/h.
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

"""
The plain data of the toy market. `units`, `demand` and `interconnector` define the `System` built by
`toy_system`; `fcas`, the constraints and the loss parameters are not in the `System` and are
keyed by component name.
"""
struct Market
    regions::Vector{String}
    units::Vector{Unit}
    demand::Dict{String, Float64}
    interconnector::Interconnector
    constraints::Vector{LinearConstraint}
    fcas::Dict{String, FCASOffer}
end

#<< types

# ## Accessors on the plain data

#>> accessors
price(b::Bid) = b.price
quantity(b::Bid) = b.quantity
find_unit(market::Market, id) = only(u for u in market.units if String(u.name) == String(id))
is_semi_scheduled(unit::Unit) = !isnothing(unit.uigf)
"MW the unit may be dispatched to: `MAXAVAIL`, capped by the `UIGF` of a semi-scheduled unit."
availability(unit::Unit) = isnothing(unit.uigf) ? unit.max_avail : min(unit.max_avail, unit.uigf)
"MW the unit can add / shed within one interval from its initial MW."
ramp_up(unit::Unit) = unit.ramp_up_mwh * INTERVAL_H
ramp_down(unit::Unit) = unit.ramp_down_mwh * INTERVAL_H

fcas_names(market::Market) = sort!(collect(keys(market.fcas)))
fcas_bids(market::Market, name) = market.fcas[name].bids
trapezium(market::Market, name) = market.fcas[name].trapezium
max_avail(t::Trapezium) = t.max_avail
upper_slope(t::Trapezium) = (t.enablement_max - t.high_breakpoint) / t.max_avail
lower_slope(t::Trapezium) = (t.low_breakpoint - t.enablement_min) / t.max_avail

"The loss in MW of interconnector `ic` at `flow` MW, quadratic in the flow."
loss_at(ic::Interconnector, flow) = ic.loss_coefficient / 2 * flow^2
"The loss at zero flow of the chord that brackets it; subtracting it makes the linearised curve lose nothing at zero flow."
function zero_flow_chord_loss(ic::Interconnector)
    bp = ic.breakpoints
    i = findfirst(i -> bp[i] < 0 < bp[i + 1], 1:(length(bp) - 1))
    isnothing(i) && return 0.0
    return -ic.loss_coefficient * bp[i] * bp[i + 1] / 2
end
"The interconnector's loss curve linearised on its breakpoints, as `(from_mw, to_mw, slope)` per segment."
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
        Unit(:COAL1, "NSW1", 600.0, 600.0, nothing, 420.0, 600.0, 600.0, [Bid(200, 25), Bid(150, 35), Bid(150, 55), Bid(100, 90)]),
        Unit(:WIND1, "NSW1", 200.0, 200.0, 150.0, 140.0, 1200.0, 1200.0, [Bid(200, 0)]),
        Unit(:GAS1, "VIC1", 400.0, 400.0, nothing, 180.0, 1800.0, 1800.0, [Bid(100, 70), Bid(150, 110), Bid(150, 250)]),
    ],
    Dict("NSW1" => 450.0, "VIC1" => 380.0),
    Interconnector("NSW1-VIC1", "NSW1", "VIC1", 100.0, 0.0006, 0.5, [-100.0, -60.0, -20.0, 20.0, 60.0, 100.0]),
    [
        LinearConstraint("N_COAL_LIMIT", :LE, 375.0, 5.0, [Term(:energy, :COAL1, 1.0)]),
        LinearConstraint("F_NSW_R6", :GE, 40.0, 1.0, [Term(:raise6, :COAL1, 1.0)]),
        LinearConstraint("F_VIC_R6", :GE, 30.0, 1.0, [Term(:raise6, :GAS1, 1.0)]),
    ],
    Dict(
        "COAL1" => FCASOffer(Trapezium(150, 200, 350, 450, 60), [Bid(20, 2), Bid(40, 8)]),
        "GAS1" => FCASOffer(Trapezium(50, 100, 300, 400, 40), [Bid(40, 12)]),
    ),
);
#<< market

"The same market with a lossless interconnector and no generic constraints: the part of NEMDE a stock PSI formulation can express."
function energy_market(market::Market)
    ic = market.interconnector
    lossless = Interconnector(ic.name, ic.from, ic.to, ic.max_flow, 0.0, ic.from_loss_share, ic.breakpoints)
    return Market(market.regions, market.units, market.demand, lossless, LinearConstraint[], market.fcas)
end

# ## The System

"""
    toy_system(market) -> PSY.System

Builds the energy part of `market` as a `PowerSystems.System` at `BASE_POWER`: one `Area` and `ACBus` per
region, a `ThermalStandard` or `RenewableDispatch` per unit with its offer as a cost curve and its dispatch
envelope as the active power limits (the rating for a renewable unit), a `PowerLoad` per region with a
demand time series, and the `AreaInterchange` with its flow limits. Losses, FCAS and generic constraints
are not added. With `nem = true` the units are stock `ThermalStandard` and `RenewableDispatch` with a zero cost and an empty [`NEMUnitData`](@ref) attached, and no cost curve: the caller attaches their offers.

# Arguments

- `market`: the toy market, or its `energy_market`.
- `nem`: attach an empty [`NEMUnitData`](@ref) to each unit, as a replay system carries.

# Returns

- The `PSY.System`, with the demand series transformed into windows of two intervals.
"""
function toy_system(market::Market; nem::Bool = false)
    sys = PSY.System(BASE_POWER)
    areas = Dict(r => PSY.Area(; name = r) for r in market.regions)
    PSY.add_components!(sys, collect(values(areas)))
    buses = Dict(
        r => PSY.ACBus(;
            number = i,
            name = "$(r)-node",
            base_voltage = 330.0,
            bustype = PSY.ACBusTypes.PQ,
            area = areas[r],
            available = true,
            angle = 0.0,
            magnitude = 1.0,
            voltage_limits = (min = 0.9, max = 1.1),
        )
            for (i, r) in enumerate(market.regions)
    )
    PSY.add_components!(sys, collect(values(buses)))
    for u in market.units
        unit = _psy_unit(u, buses[u.region]; nem)
        PSY.add_component!(sys, unit)
        nem && attach_nem_unit_data!(sys, unit)
    end
    for r in market.regions
        mw = market.demand[r]
        load = PSY.PowerLoad(;
            name = "$(r)-load",
            available = true,
            bus = buses[r],
            active_power = mw / BASE_POWER,
            reactive_power = 0.0,
            base_power = BASE_POWER,
            max_active_power = mw / BASE_POWER,
            max_reactive_power = 0.0,
        )
        PSY.add_component!(sys, load)
        PSY.add_time_series!(
            sys,
            load,
            PSY.SingleTimeSeries(;
                name = "max_active_power",
                data = PSY.TimeSeries.TimeArray([T0, T0 + RESOLUTION], [1.0, 1.0]),
                scaling_factor_multiplier = PSY.get_max_active_power,
            ),
        )
    end
    PSY.transform_single_time_series!(sys, 2 * RESOLUTION, RESOLUTION)
    ic = market.interconnector
    PSY.add_component!(
        sys,
        PSY.AreaInterchange(;
            name = ic.name,
            available = true,
            active_power_flow = 0.0,
            from_area = areas[ic.from],
            to_area = areas[ic.to],
            flow_limits = (from_to = ic.max_flow / BASE_POWER, to_from = ic.max_flow / BASE_POWER),
        ),
    )
    return sys
end

# The envelope is the dispatch range of one interval: availability, and the ramp from the initial output.
function _psy_unit(u::Unit, bus::PSY.ACBus; nem::Bool = false)
    floor_mw = max(0.0, u.initial_mw - ramp_down(u))
    ceiling_mw = min(availability(u), u.initial_mw + ramp_up(u))
    offer = PSY.CostCurve(
        PSY.PiecewiseIncrementalCurve(0.0, [0.0; cumsum(quantity.(u.bids))], price.(u.bids)),
    )
    if nem && is_semi_scheduled(u)
        return PSY.RenewableDispatch(;
            name = String(u.name), available = true, bus = bus, active_power = 0.0, reactive_power = 0.0,
            rating = ceiling_mw / BASE_POWER, prime_mover_type = PSY.PrimeMovers.WT, reactive_power_limits = nothing,
            power_factor = 1.0, operation_cost = PSY.RenewableGenerationCost(nothing), base_power = BASE_POWER,
        )
    elseif nem
        return PSY.ThermalStandard(;
            name = String(u.name), available = true, status = true, bus = bus, active_power = 0.0, reactive_power = 0.0,
            rating = u.capacity / BASE_POWER,
            active_power_limits = (min = floor_mw / BASE_POWER, max = ceiling_mw / BASE_POWER),
            reactive_power_limits = nothing, ramp_limits = nothing, operation_cost = PSY.ThermalGenerationCost(nothing),
            base_power = BASE_POWER, time_limits = nothing, must_run = false,
            prime_mover_type = PSY.PrimeMovers.GT, fuel = PSY.ThermalFuels.NATURAL_GAS,
        )
    end
    if is_semi_scheduled(u)
        return PSY.RenewableDispatch(;
            name = String(u.name),
            available = true,
            bus = bus,
            active_power = 0.0,
            reactive_power = 0.0,
            rating = ceiling_mw / BASE_POWER,
            prime_mover_type = PSY.PrimeMovers.WT,
            reactive_power_limits = nothing,
            power_factor = 1.0,
            operation_cost = PSY.RenewableGenerationCost(offer),
            base_power = BASE_POWER,
        )
    end
    return PSY.ThermalStandard(;
        name = String(u.name),
        available = true,
        status = true,
        bus = bus,
        active_power = 0.0,
        reactive_power = 0.0,
        rating = u.capacity / BASE_POWER,
        active_power_limits = (min = floor_mw / BASE_POWER, max = ceiling_mw / BASE_POWER),
        reactive_power_limits = nothing,
        ramp_limits = nothing,
        operation_cost = PSY.ThermalGenerationCost(; variable = offer, fixed = 0.0, start_up = 0.0, shut_down = 0.0),
        base_power = BASE_POWER,
        time_limits = nothing,
        prime_mover_type = PSY.PrimeMovers.GT,
        fuel = PSY.ThermalFuels.NATURAL_GAS,
    )
end

# ## Reading the energy data from the System

#>> system_accessors
"Names of the energy generators (`ThermalStandard` and `RenewableDispatch`) in `sys`, sorted."
generator_names(sys::PSY.System) = sort!([PSY.get_name(g) for g in PSY.get_components(PSY.Generator, sys)])
"Region (`Area`) of a generator, read from its bus."
generator_region(sys::PSY.System, name) = PSY.get_name(PSY.get_area(PSY.get_bus(PSY.get_component(PSY.Generator, sys, name))))
"Names of the regions (`Area`s) of `sys`, sorted."
region_names(sys::PSY.System) = sort!([PSY.get_name(a) for a in PSY.get_components(PSY.Area, sys)])
"Generators of region `region`."
units_in(sys::PSY.System, region) = [n for n in generator_names(sys) if generator_region(sys, n) == region]

"The offered price bands of a generator, read from the incremental cost curve of its operation cost."
function offer_bids(sys::PSY.System, name)
    g = PSY.get_component(PSY.Generator, sys, name)
    curve = PSY.get_function_data(PSY.get_variable(PSY.get_operation_cost(g)))
    x = PSY.get_x_coords(curve)
    y = PSY.get_y_coords(curve)
    return [Bid(x[j + 1] - x[j], y[j]) for j in eachindex(y)]
end

"Lower and upper MW of a generator's dispatch envelope for the interval. A renewable unit has no output floor."
function envelope(sys::PSY.System, name)
    g = PSY.get_component(PSY.Generator, sys, name)
    g isa PSY.RenewableDispatch && return (0.0, PSY.get_rating(g) * BASE_POWER)
    limits = PSY.get_active_power_limits(g)
    return (limits.min * BASE_POWER, limits.max * BASE_POWER)
end

"Demand of a region in MW, the `max_active_power` of its `PowerLoad`."
region_demand(sys::PSY.System, region) = PSY.get_max_active_power(PSY.get_component(PSY.PowerLoad, sys, "$(region)-load")) * BASE_POWER

"The `AreaInterchange` between the two regions."
interconnector(sys::PSY.System) = only(PSY.get_components(PSY.AreaInterchange, sys))
"Flow limit of the interconnector in MW, the same in both directions."
flow_limit(sys::PSY.System) = PSY.get_flow_limits(interconnector(sys)).from_to * BASE_POWER
#<< system_accessors
