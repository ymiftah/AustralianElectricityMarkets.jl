begin
    using AustralianElectricityMarkets
    using AustralianElectricityMarketsSimulations
    using PowerSystems
    using PowerSimulations
    using JuMP
    using HiGHS
    using DataFrames
    using Dates
    using InteractiveUtils: subtypes
    using CairoMakie
end;

import PowerSystems as PSY
import PowerSimulations as PSI
import AustralianElectricityMarketsSimulations as AEMSim

# # From NEM dispatch to PowerSimulations.jl
#
# The National Electricity Market is managed by AEMO (Australian Electricity Market Operator),
# and the market clearing process is run every 5 minutes by solving a large optimisation problem.
# The NEM Dispatch Engine (NEMDE) picks the energy and frequency-control (FCAS) quantities that minimise the total cost
# of the offers participants submitted, subject to the physical limits of the units and the
# network.
#
# This page builds that linear programme twice, on the same small market:
#
# 1. **By hand in JuMP**, one concept at a time, so every NEM modelling idea (bid stack,
#    ramping from the previous dispatch, regional balance, interconnector limits, the FCAS
#    trapezium, generic constraints) is visible as a handful of lines.
# 2. **Through PowerSimulations.jl (PSI)**, where the same problem is *assembled* from a
#    [`PowerSystems.jl`](https://nrel-sienna.github.io/PowerSystems.jl/stable/) `System` (the
#    data) and a PSI `ProblemTemplate` (the formulation), then checked against the hand-written
#    model.
#
#
# !!! warning "AEMSim is a work in progress"
#     The PSI extension is being built in stages. This page uses what is merged today:
#     the energy dispatch formulation (`NEMReplayDispatch`), the FCAS market formulation
#     (`FCASMarket`) with its trapezium rows, and generic constraints with energy terms
#     (`LinearFactorLimit`). Three pieces are **not** merged yet and are called out where they
#     would appear: FCAS requirements as generic-constraint terms, elastic constraints with
#     violation penalties, and interconnector losses. See [Roadmap](@ref) and
#     [What is not here yet](@ref intro-psi-gaps).
#
# !!! note "References"
#     See [References](@ref intro-psi-references) at the end. For the market rules, AEMO's
#     [*FCAS Model in NEMDE*](https://nempy.readthedocs.io/en/latest/_downloads/e3c8a21d3084db332a30bd0d564e93c3/FCAS%20Model%20in%20NEMDE.pdf)
#     defines the trapezium and joint constraints used below, and the
#     [NEMDE queue](https://www.aemo.com.au/energy-systems/electricity/national-electricity-market-nem/system-operations/dispatch)
#     describes the dispatch process. For the software, the
#     [PSI documentation](https://nrel-sienna.github.io/PowerSimulations.jl/stable/) describes
#     the build machinery summarised in [Part 2](@ref intro-psi-part2).

# ## The toy market
#
# Two regions, one network node per region, joined by one interconnector. Three scheduled
# units: a coal unit and a wind farm in `NSW1`, a gas unit in `VIC1`. We clear a single
# 5-minute dispatch interval.
#
# Every unit is described by exactly the quantities NEMDE reads. A *bid stack* of price bands
# ($/MWh, up to ten bands in the real market), an *availability* (`MAXAVAIL` for a scheduled
# unit, the forecast `UIGF` for a semi-scheduled one such as wind), the *initial MW* the unit
# was at when the interval started, and a *ramp rate* (MW/h in the NEMWEB data).

const BASE_POWER = 100.0                 # MVA, the System base
const T0 = DateTime(2025, 1, 1, 12, 0)   # the dispatch interval being cleared
const RESOLUTION = Minute(5)
const INTERVAL_H = 5 / 60                # interval length in hours

units = (
    COAL1 = (
        region = "NSW1", capacity = 600.0, avail = 600.0, initial = 420.0, ramp_mwh = 600.0,
        bands = [(200.0, 25.0), (150.0, 35.0), (150.0, 55.0), (100.0, 90.0)],
    ),
    WIND1 = (
        region = "NSW1", capacity = 200.0, avail = 150.0, initial = 140.0, ramp_mwh = 1200.0,
        bands = [(150.0, 0.0)],
    ),
    GAS1 = (
        region = "VIC1", capacity = 400.0, avail = 400.0, initial = 150.0, ramp_mwh = 1800.0,
        bands = [(100.0, 70.0), (150.0, 110.0), (150.0, 250.0)],
    ),
)
demand = (NSW1 = 450.0, VIC1 = 380.0)    # MW
interconnector = (from = "NSW1", to = "VIC1", max_from = 100.0, max_to = 120.0)  # MW

@show DataFrame(
    unit = collect(String.(keys(units))),
    region = [u.region for u in units],
    availability_MW = [u.avail for u in units],
    initial_MW = [u.initial for u in units],
    ramp_MW_per_h = [u.ramp_mwh for u in units],
    bands = [join(["$(b[1]) MW @ \$$(b[2])" for b in u.bands], ", ") for u in units],
)

# ## Part 1: the NEM dispatch as a JuMP model
#
# Everything below is plain [JuMP](https://jump.dev) over the `units`, `demand` and
# `interconnector` tuples above: no `PowerSystems.jl`, no `PowerSimulations.jl`.
#
# ### The bid stack
#
# NEMDE does not see a cost function, it sees *offers*: each band is a quantity a participant
# is willing to supply at or above a price. Because bands are priced in increasing order, the
# cheapest MW is always taken first (except when network constraints apply as we will see further down),
# so a unit's dispatch is the sum of its band quantities and each band variable is bounded by the band width:
#
# ```math
# p_u = \sum_b q_{u,b}, \qquad 0 \le q_{u,b} \le Q_{u,b}, \qquad
# \text{cost} = \sum_u \sum_b \pi_{u,b}\, q_{u,b}\, \Delta
# ```
#
# where ``\Delta`` is the interval length in hours (offers are in $/MWh).

unit_names = collect(keys(units))

# The same offers drawn as a merit order per region: the supply curve the market clears
# against. Wind offers at \$0 (drawn as a thin bar), coal climbs through four bands, gas starts at \$70.

function merit_order(region)
    steps = [
        (price = b[2], mw = b[1], unit = String(u)) for u in unit_names if units[u].region == region
            for b in units[u].bands
    ]
    sort!(steps; by = s -> s.price)
    return steps
end

function plot_merit_order!(ax, region; requirement = nothing, price = nothing)
    steps = merit_order(region)
    colors = Dict(String(u) => c for (u, c) in zip(unit_names, Makie.wong_colors()))
    left = 0.0
    for s in steps
        poly!(
            ax, Rect2f(left, 0.0, s.mw, max(s.price, 3.0)); color = (colors[s.unit], 0.8),
            strokecolor = colors[s.unit], strokewidth = 1,
        )
        left += s.mw
    end
    isnothing(requirement) || vlines!(ax, requirement; color = :white, linestyle = :dash)
    isnothing(price) || hlines!(ax, price; color = :tomato, linestyle = :dot)
    return colors
end

let
    fig = Figure(size = (900, 320))
    for (i, region) in enumerate(("NSW1", "VIC1"))
        ax = Axis(
            fig[1, i]; title = region, xlabel = "Cumulative offered MW", ylabel = "Offer price (\$/MWh)",
        )
        plot_merit_order!(ax, region)
        ylims!(ax, 0, 260)
    end
    colors = Dict(String(u) => c for (u, c) in zip(unit_names, Makie.wong_colors()))
    Legend(
        fig[2, 1:2],
        [PolyElement(color = colors[String(u)]) for u in unit_names], String.(unit_names);
        orientation = :horizontal, tellheight = true,
    )
    fig
end

# ### The JuMP model

model = JuMP.Model(HiGHS.Optimizer)
set_silent(model)

@variable(model, units[u].bands[b][1] >= band[u in unit_names, b in eachindex(units[u].bands)] >= 0)

@expression(model, dispatch[u in unit_names], sum(band[u, b] for b in eachindex(units[u].bands)))
energy_cost = sum(
    units[u].bands[b][2] * band[u, b] * INTERVAL_H for u in unit_names for b in eachindex(units[u].bands)
)
@objective(model, Min, energy_cost)


# ### The unit's dispatchable envelope
#
# A unit cannot be dispatched anywhere between zero and its offered capacity: NEMDE bounds it
# by what it can *physically reach in one interval from where it started*. Two constraints
# build that envelope:
#
# ```math
# p_u \le \text{AVAIL}_u, \qquad
# -R^{\downarrow}_u \Delta \le p_u - p^{0}_u \le R^{\uparrow}_u \Delta
# ```
#
# with ``p^0`` the `INITIALMW` of the unit and ``R`` its ramp rate in MW/h. These are the
# *initial conditions for the ramping constraints* of this page: nothing in the market is
# carried over from the previous interval but this one number per unit.


envelope = DataFrame(
    unit = String.(unit_names),
    floor_MW = [max(0.0, units[u].initial - units[u].ramp_mwh * INTERVAL_H) for u in unit_names],
    ceiling_MW = [min(units[u].avail, units[u].initial + units[u].ramp_mwh * INTERVAL_H) for u in unit_names],
)

# TODO add a figure illustrating the envelope and the dispatch point for an interval.
# The range of possible loads is bounded by the ramps. the up and down ramps may be different.

@constraint(model, availability[u in unit_names], dispatch[u] <= units[u].avail)
@constraint(model, ramp_up[u in unit_names], dispatch[u] - units[u].initial <= units[u].ramp_mwh * INTERVAL_H)
@constraint(model, ramp_down[u in unit_names], units[u].initial - dispatch[u] <= units[u].ramp_mwh * INTERVAL_H)


# ### Regional balance and the interconnector
#
# Each region must supply its own demand plus whatever it exports. The interconnector flow is
# a single signed variable bounded by the limits in each direction (positive is `NSW1` to
# `VIC1`). The *price* of a region is the marginal cost of one more MW of demand there, which
# is exactly the dual of its balance constraint:
#
# ```math
# \sum_{u \in r} p_u - \text{flow}_{r} = D_r, \qquad
# \lambda_r = \frac{\partial \,\text{cost}}{\partial D_r}
# ```
#
# When the interconnector is not binding both regions share one price. When it binds the cheap
# region exports as much as it can and the two prices separate: a congestion rent.

@variable(model, -interconnector.max_to <= flow <= interconnector.max_from)
inj(region) = sum(dispatch[u] for u in unit_names if units[u].region == region)
@constraint(model, balance_nsw, inj("NSW1") - flow == demand.NSW1)
@constraint(model, balance_vic, inj("VIC1") + flow == demand.VIC1)

# Solve the energy-only problem and collect the quantities of interest.
# Duals are per MW *per interval*, so dividing by the interval length gives \$/MWh.

function jump_solution(model)
    optimize!(model)
    @assert termination_status(model) == OPTIMAL
    fcas_on = haskey(object_dictionary(model), :raise)
    limit_on = haskey(object_dictionary(model), :coal_limit)
    return (;
        dispatch = Dict(u => value(model[:dispatch][u]) for u in unit_names),
        flow = value(model[:flow]),
        price = Dict(
            "NSW1" => dual(model[:balance_nsw]) / INTERVAL_H,
            "VIC1" => dual(model[:balance_vic]) / INTERVAL_H,
        ),
        objective = objective_value(model),
        fcas = fcas_on ? Dict(u => value(model[:raise][u]) for u in keys(fcas)) : nothing,
        fcas_price = fcas_on ?
            Dict(r => dual(model[:requirement_row][r]) / INTERVAL_H for r in ("NSW1", "VIC1")) : nothing,
        limit_price = limit_on ? dual(model[:coal_limit]) / INTERVAL_H : nothing,
    )
end

energy_only = jump_solution(model)

# The cheap `NSW1` coal and wind export up to the interconnector limit; `VIC1` has to
# fill the rest with its own expensive gas, so the interconnector binds and the prices
# separate.

fig = Figure(size = (900, 360))
for (i, region) in enumerate(("NSW1", "VIC1"))
    ax = Axis(
        fig[1, i]; title = "$region (price \$$(round(energy_only.price[region]; digits = 1))/MWh)",
        xlabel = "Cumulative offered MW", ylabel = "Offer price (\$/MWh)",
    )
    exported = region == "NSW1" ? energy_only.flow : -energy_only.flow
    plot_merit_order!(
        ax, region; requirement = demand[Symbol(region)] + exported, price = energy_only.price[region],
    )
    ylims!(ax, 0, 260)
end
Label(
    fig[0, :], "Dashed: demand plus exports (MW) cleared in the region; dotted: regional price";
    tellwidth = false,
)
fig

# ### FCAS and the trapezium
#
# Frequency control ancillary services are procured in the same optimisation. Take
# **RAISE6SEC**, 6-second raise contingency FCAS: capacity held in reserve so output can rise
# quickly if a generator trips. Every region has a *requirement* (MW) and every offering unit
# submits an FCAS offer (``\$/MW/h``) together with a **trapezium** that says how much FCAS
# it can offer *as a function of its energy dispatch* (AEMO, *FCAS Model in NEMDE* §2-3):
#
# ```math
# 0 \le f_u \le \text{MaxAvail}_u, \qquad
# p_u + \underbrace{\frac{E^{\max}_u - H_u}{\text{MaxAvail}_u}}_{\text{UpperSlope}} f_u \le E^{\max}_u, \qquad
# p_u - \underbrace{\frac{L_u - E^{\min}_u}{\text{MaxAvail}_u}}_{\text{LowerSlope}} f_u \ge E^{\min}_u
# ```
#
# A unit can only sell the FCAS the trapezium allows at its energy dispatch: a unit running
# near its maximum has little room left to raise, so FCAS and energy compete for the same MW.
# The regional requirement is a plain sum, and its dual is the FCAS price.

fcas = (
    COAL1 = (region = "NSW1", trapezium = (150.0, 200.0, 350.0, 450.0, 60.0), bands = [(20.0, 2.0), (40.0, 8.0)]),
    GAS1 = (region = "VIC1", trapezium = (50.0, 100.0, 300.0, 400.0, 40.0), bands = [(40.0, 12.0)]),
)
requirement = (NSW1 = 40.0, VIC1 = 30.0)   # MW of RAISE6SEC per region

DataFrame(
    unit = String.(keys(fcas)),
    enablement_min = [f.trapezium[1] for f in fcas],
    low_breakpoint = [f.trapezium[2] for f in fcas],
    high_breakpoint = [f.trapezium[3] for f in fcas],
    enablement_max = [f.trapezium[4] for f in fcas],
    max_avail = [f.trapezium[5] for f in fcas],
)

# The model is extended in place: new variables, new rows, and the FCAS offer cost added to
# the objective.

fcas_units = collect(keys(fcas))
@variable(model, raise[u in fcas_units] >= 0)
@variable(model, fcas_band[u in fcas_units, b in eachindex(fcas[u].bands)] >= 0)
for u in fcas_units
    for b in eachindex(fcas[u].bands)
        set_upper_bound(fcas_band[u, b], fcas[u].bands[b][1])
    end
    emin, low, high, emax, max_avail = fcas[u].trapezium
    @constraint(model, raise[u] == sum(fcas_band[u, b] for b in eachindex(fcas[u].bands)))
    set_upper_bound(raise[u], max_avail)
    @constraint(model, dispatch[u] + (emax - high) / max_avail * raise[u] <= emax)
    @constraint(model, dispatch[u] - (low - emin) / max_avail * raise[u] >= emin)
end
@constraint(
    model, requirement_row[r in ("NSW1", "VIC1")],
    sum(raise[u] for u in fcas_units if fcas[u].region == r) >= requirement[Symbol(r)],
)
fcas_cost = sum(
    fcas[u].bands[b][2] * fcas_band[u, b] * INTERVAL_H for u in fcas_units for b in eachindex(fcas[u].bands)
)
set_objective_function(model, objective_function(model) + fcas_cost)

co_optimised = jump_solution(model)

# Co-optimisation changes the *energy* outcome. `NSW1` has to hold 40 MW of RAISE6SEC on the
# coal unit; at 400 MW of energy the trapezium only lets it offer 30 MW, so energy is pushed
# down until the joint row is satisfied. That removes cheap export, the interconnector comes
# off its limit, and the two regions now share the gas price. The FCAS price in `NSW1` is not
# the \$8/MW/h of the marginal FCAS offer: it also contains the energy the coal unit gives up
# (``1/\text{UpperSlope} \times (\$250 - \$55)``).

DataFrame(
    quantity = [
        "COAL1 energy (MW)", "GAS1 energy (MW)", "Flow NSW1 to VIC1 (MW)",
        "NSW1 energy price (\$/MWh)", "VIC1 energy price (\$/MWh)",
        "NSW1 RAISE6SEC price (\$/MW/h)", "VIC1 RAISE6SEC price (\$/MW/h)", "Objective (\$)",
    ],
    energy_only = [
        energy_only.dispatch[:COAL1], energy_only.dispatch[:GAS1], energy_only.flow,
        energy_only.price["NSW1"], energy_only.price["VIC1"], NaN, NaN, energy_only.objective,
    ],
    co_optimised = [
        co_optimised.dispatch[:COAL1], co_optimised.dispatch[:GAS1], co_optimised.flow,
        co_optimised.price["NSW1"], co_optimised.price["VIC1"],
        co_optimised.fcas_price["NSW1"], co_optimised.fcas_price["VIC1"], co_optimised.objective,
    ],
)

# The coal unit's trapezium in the energy/FCAS plane. The shaded region is every
# `(energy, FCAS)` pair the unit may be dispatched at; the markers are where the two solves
# put it (energy-only has no FCAS, so it sits on the horizontal axis).

function plot_trapezium!(ax, trapezium, energy, raise_mw; colors = Makie.wong_colors())
    emin, low, high, emax, max_avail = trapezium
    poly!(
        ax, Point2f[(emin, 0), (low, max_avail), (high, max_avail), (emax, 0)];
        color = (colors[1], 0.35), strokecolor = colors[1], strokewidth = 2,
    )
    scatter!(ax, energy, raise_mw; color = :tomato, markersize = 14)
    return
end

fig = Figure(size = (900, 340))
ax = Axis(fig[1, 1]; title = "COAL1 RAISE6SEC", xlabel = "Energy dispatch (MW)", ylabel = "RAISE6SEC (MW)")
plot_trapezium!(ax, fcas.COAL1.trapezium, co_optimised.dispatch[:COAL1], co_optimised.fcas[:COAL1])
scatter!(ax, energy_only.dispatch[:COAL1], 0.0; color = :white, markersize = 12, marker = :diamond)
ax = Axis(fig[1, 2]; title = "GAS1 RAISE6SEC", xlabel = "Energy dispatch (MW)", ylabel = "RAISE6SEC (MW)")
plot_trapezium!(ax, fcas.GAS1.trapezium, co_optimised.dispatch[:GAS1], co_optimised.fcas[:GAS1])
scatter!(ax, energy_only.dispatch[:GAS1], 0.0; color = :white, markersize = 12, marker = :diamond)
fig

# ### A generic constraint
#
# NEMDE also enforces thousands of *generic constraints*: linear inequalities over unit
# outputs, interconnector flows and FCAS, the form network and system-security limits take
# (`LHS <= RHS`). Their dual is the marginal value of the constraint, and the
# constraint's effect on prices is the "congestion" NEMWEB reports as constraint attribution.
# Here a stability limit caps the coal unit just below where co-optimisation left it.

coal_limit_mw = 380.0
@constraint(model, coal_limit, dispatch[:COAL1] <= coal_limit_mw)
constrained = jump_solution(model)

DataFrame(
    quantity = [
        "COAL1 energy (MW)", "Flow NSW1 to VIC1 (MW)", "NSW1 energy price (\$/MWh)",
        "VIC1 energy price (\$/MWh)", "Constraint marginal value (\$/MWh)",
    ],
    value = [
        constrained.dispatch[:COAL1], constrained.flow, constrained.price["NSW1"],
        constrained.price["VIC1"], constrained.limit_price,
    ],
)

# Part 1 is the whole NEM dispatch problem for this market: one objective and four families
# of rows, all linear. Everything NEMDE does at national scale is this model with more
# units, more bands, more services and a lot more generic constraints. The remaining job, and
# the one PSI helps with, is *building* such a model from market data without rewriting it for
# every study.

# ## [Part 2: building the same model with PowerSimulations.jl](@id intro-psi-part2)
#
# Writing the JuMP model by hand does not scale: every new unit type, service or constraint
# touches the same objective, the same balance rows and the same bookkeeping. PSI separates
# *what the system is* from *how it is modelled*.
#
# | | Holds | Package | Example in this page |
# | --- | --- | --- | --- |
# | **Data** | Components, their parameters and time series | `PowerSystems.jl` (PSY), extended by AEM | `ThermalStandard`, `RenewableDispatch`, `AreaInterchange`, [`FCASService`](@ref), `"initial_mw"` series |
# | **Formulation** | Which variables, constraints and costs a component type produces | `PowerSimulations.jl` (PSI), extended by AEMSim | `NEMReplayDispatch`, `FCASMarket`, `LinearFactorLimit` |
# | **Template** | The mapping *(component type, formulation)* for a problem | PSI `ProblemTemplate` | `set_nem_dispatch_models!`, `set_service_model!` |
#
# A `DecisionModel` takes a `System` and a template and writes the JuMP problem. Which JuMP
# code runs for a component is decided by Julia's **multiple dispatch** on the pair
# *(component type, formulation type)*: `construct_device!(container, sys, stage, model, network)`
# has a method for each combination, and the template simply names the formulation to use.
#
# ### Step 1: the System (data)
#
# AEM's job is to put every NEM input a formulation reads into typed `System` data. For real
# markets `nem_system` does this from NEMWEB (see [Overview of the NEM](@ref)); here the same
# structure is assembled by hand. Components first:

function toy_system()
    sys = PSY.System(BASE_POWER)
    areas = Dict(r => PSY.Area(; name = r) for r in ("NSW1", "VIC1"))
    PSY.add_components!(sys, collect(values(areas)))
    buses = Dict(
        r => PSY.ACBus(;
            number = i, name = "$(r)-node", base_voltage = 330.0, bustype = PSY.ACBusTypes.PQ,
            area = areas[r], available = true, angle = 0.0, magnitude = 1.0,
            voltage_limits = (min = 0.9, max = 1.1),
        ) for (i, r) in enumerate(("NSW1", "VIC1"))
    )
    PSY.add_components!(sys, collect(values(buses)))
    for (name, u) in pairs(units)
        bus = buses[u.region]
        device = if name == :WIND1
            PSY.RenewableDispatch(;
                name = String(name), available = true, bus, active_power = 0.0, reactive_power = 0.0,
                rating = u.capacity / BASE_POWER, prime_mover_type = PSY.PrimeMovers.WT,
                reactive_power_limits = nothing, power_factor = 1.0,
                operation_cost = PSY.RenewableGenerationCost(nothing), base_power = BASE_POWER,
            )
        else
            PSY.ThermalStandard(;
                name = String(name), available = true, status = true, bus, active_power = 0.0,
                reactive_power = 0.0, rating = u.capacity / BASE_POWER,
                active_power_limits = (min = 0.0, max = u.capacity / BASE_POWER),
                reactive_power_limits = nothing, ramp_limits = nothing,
                operation_cost = PSY.ThermalGenerationCost(nothing), base_power = BASE_POWER,
                time_limits = nothing,
                prime_mover_type = name == :COAL1 ? PSY.PrimeMovers.ST : PSY.PrimeMovers.GT,
                fuel = name == :COAL1 ? PSY.ThermalFuels.COAL : PSY.ThermalFuels.NATURAL_GAS,
            )
        end
        PSY.add_component!(sys, device)
    end
    for (region, mw) in pairs(demand)
        PSY.add_component!(
            sys,
            PSY.PowerLoad(;
                name = "$(region)-load", available = true, bus = buses[String(region)],
                active_power = mw / BASE_POWER, reactive_power = 0.0, base_power = BASE_POWER,
                max_active_power = mw / BASE_POWER, max_reactive_power = 0.0,
            ),
        )
    end
    PSY.add_component!(
        sys,
        PSY.AreaInterchange(;
            name = "NSW1-VIC1", available = true, active_power_flow = 0.0,
            from_area = areas[interconnector.from], to_area = areas[interconnector.to],
            flow_limits = (
                from_to = interconnector.max_from / BASE_POWER, to_from = interconnector.max_to / BASE_POWER,
            ),
        ),
    )
    return sys
end

sys = toy_system()

# The market data comes next, attached to the components as time series. This is what AEM's
# setters (`set_market_bids!`, `set_nem_dispatch_limits!`, `set_fcas_bids!`) do from
# NEMWEB tables; the series *names* are the contract between AEM and AEMSim.
#
# | Series | Meaning | Written by |
# | --- | --- | --- |
# | `"variable_cost"` (a `MarketBidCost`) | the offer bands | `set_market_bids!` |
# | `"max_active_power"` | availability, as a fraction of the unit rating | `set_nem_dispatch_limits!` |
# | `"ramp_up_rate"`, `"ramp_down_rate"` | ramp rates, per-unit per minute | `set_nem_dispatch_limits!` |
# | `"initial_mw"` | the unit's `INITIALMW` | `set_nem_dispatch_limits!` |
# | `"fcas_trapezium_<service>"`, `"fcas_curve_<service>"` | the FCAS trapezium and offer | `set_fcas_bids!` |
#
# A forecast needs at least two points, so every series carries two timestamps and the
# model's horizon is a single interval.

function attach_energy_data!(sys)
    stamps = [T0, T0 + RESOLUTION]
    series(name, value; multiplier = nothing) = PSY.SingleTimeSeries(;
        name, data = PSY.TimeSeries.TimeArray(stamps, fill(value, length(stamps))),
        scaling_factor_multiplier = multiplier,
    )
    for (name, u) in pairs(units)
        device = PSY.get_component(PSY.StaticInjection, sys, String(name))
        offer = PSY.PiecewiseStepData([0.0; cumsum(first.(u.bands))], last.(u.bands))
        AustralianElectricityMarkets._set_incremental_bid_cost!(
            sys, device, (piecewise_step_data = fill(offer, length(stamps)),), T0, RESOLUTION,
        )
        PSY.add_time_series!(
            sys, device, series("max_active_power", u.avail / u.capacity; multiplier = PSY.get_max_active_power),
        )
        PSY.add_time_series!(sys, device, series("ramp_up_rate", u.ramp_mwh / 60 / BASE_POWER))
        PSY.add_time_series!(sys, device, series("ramp_down_rate", u.ramp_mwh / 60 / BASE_POWER))
        PSY.add_time_series!(sys, device, series("initial_mw", u.initial / BASE_POWER))
    end
    for load in PSY.get_components(PSY.PowerLoad, sys)
        PSY.add_time_series!(
            sys, load, series("max_active_power", 1.0; multiplier = PSY.get_max_active_power),
        )
    end
    return sys
end

attach_energy_data!(sys);

# FCAS is described by data too. The trapezium and offer are series on the offering unit, and
# an [`FCASService`](@ref) is a `PSY.Service` that groups the units offering one
# `(region, service)` market.

function attach_fcas_data!(sys)
    for (name, f) in pairs(fcas)
        device = PSY.get_component(PSY.StaticInjection, sys, String(name))
        emin, low, high, emax, max_avail = f.trapezium ./ BASE_POWER
        trapezium = Tuple(
            FCASTrapezium(;
                enablement_min = emin, low_breakpoint = low, high_breakpoint = high,
                enablement_max = emax, max_avail = max_avail,
            ),
        )
        curve = PSY.PiecewiseStepData([0.0; cumsum(first.(f.bands))] ./ BASE_POWER, last.(f.bands))
        for (series_name, value) in (
                "fcas_trapezium_RAISE6SEC" => trapezium, "fcas_curve_RAISE6SEC" => curve,
            )
            PSY.add_time_series!(
                sys, device,
                PSY.Deterministic(;
                    name = series_name, data = Dict(T0 => fill(value, 2)),
                    resolution = RESOLUTION, interval = RESOLUTION,
                ),
            )
        end
        service = FCASService(;
            name = "$(f.region)_RAISE6SEC", region = f.region, bid_type = BidType.RAISE6SEC,
        )
        PSY.add_service!(sys, service, [device])
    end
    return sys
end

attach_fcas_data!(sys);

# A generic constraint is a `PSY.Service` as well: its terms, a sense (`<=`) and a right-hand
# side series.

function attach_coal_limit!(sys, limit_mw)
    stamps = [T0, T0 + RESOLUTION]
    constraint = GenericConstraint(;
        name = "N_COAL_LIMIT", sense = ConstraintSense.LE, rhs = limit_mw / BASE_POWER,
        terms = ConstraintTerm[UnitTerm("COAL1", BidType.ENERGY, 1.0)],
    )
    PSY.add_service!(sys, constraint, [PSY.get_component(PSY.ThermalStandard, sys, "COAL1")])
    for (name, value) in ("rhs" => limit_mw / BASE_POWER, "invoked" => 1.0)
        PSY.add_time_series!(
            sys, constraint,
            PSY.SingleTimeSeries(;
                name, data = PSY.TimeSeries.TimeArray(stamps, fill(value, length(stamps))),
            ),
        )
    end
    return sys
end

attach_coal_limit!(sys, coal_limit_mw);
PSY.transform_single_time_series!(sys, 2 * RESOLUTION, RESOLUTION);

# The `System` now holds the whole market, and nothing yet says how to optimise it.
# Listing its component types and the series on the coal unit:

DataFrame(
    type = [
        string(nameof(T)) for T in (
                PSY.Area, PSY.ACBus, PSY.ThermalStandard, PSY.RenewableDispatch, PSY.PowerLoad,
                PSY.AreaInterchange, FCASService, GenericConstraint,
            )
    ],
    count = [
        length(PSY.get_components(T, sys)) for T in (
                PSY.Area, PSY.ACBus, PSY.ThermalStandard, PSY.RenewableDispatch, PSY.PowerLoad,
                PSY.AreaInterchange, FCASService, GenericConstraint,
            )
    ],
)

# ### Step 2: the template (formulation)
#
# The template chooses the formulation for each component type. AEMSim's
# `set_nem_dispatch_models!` inspects the `System` for every type that carries the NEM
# dispatch series and assigns `NEMReplayDispatch` to it. "Replay" means each interval's ramp
# is measured from that interval's own `"initial_mw"` series, exactly what we did by hand.

network = PSI.NetworkModel(
    PSI.AreaBalancePowerModel;
    use_slacks = true,
    duals = [PSI.CopperPlateBalanceConstraint],
)
template = PSI.ProblemTemplate(network)
types = set_nem_dispatch_models!(template, sys)
PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
PSI.set_device_model!(template, PSY.AreaInterchange, PSI.StaticBranch)
for region in ("NSW1", "VIC1")
    service = "$(region)_RAISE6SEC"
    PSI.set_service_model!(
        template, service,
        PSI.ServiceModel(FCASService, FCASMarket, service; duals = [FCASJointCapacityConstraint]),
    )
end
PSI.set_service_model!(
    template, PSI.ServiceModel(GenericConstraint, LinearFactorLimit; duals = [NEMConstraintLimit]),
)
types

# `AreaBalancePowerModel` is PSI's regional network: one balance row per `Area`, with
# `AreaInterchange` flows moving power between them. That is the NEM's regional market.
# Note what the template does *not* say: nothing about bands, ramps or trapezia. Those live in
# the formulation methods, selected by the types in the template.

# ### Step 3: the build, in order
#
# `PSI.build!` runs the construction phases in a fixed order, handing the same
# `OptimizationContainer` (a typed registry wrapping the JuMP model) to each. Devices are
# built in **two stages**: the *argument* stage adds variables, parameters and expressions;
# the *model* stage adds constraints and costs. That split exists so that a service (like
# FCAS) can add its variables into expressions a device has already declared, *before* the
# device writes the constraint on them. These are the phases of `build_impl!` in the pinned
# PSI revision:

#
# | # | Models | Hook | Adds | In this page |
# | --- | --- | --- | --- | --- |
# | 1 | Devices | `ArgumentConstructStage` | variables, parameters, expressions | `NEMReplayDispatch`: `ActivePowerVariable`, offer variables, ramp and initial-MW parameters |
# | 2 | Services | `ArgumentConstructStage` | service variables and expressions | `FCASMarket`: `FCASCapacityVariable`, joint-capacity expressions |
# | 3 | Branches | `ArgumentConstructStage` | flow variables | `StaticBranch` on `AreaInterchange` |
# | 4 | Devices | `ModelConstructStage` | constraints and costs | `NEMReplayDispatch`: availability and ramp rows, offer cost |
# | 5 | Network | `construct_network!` | balance constraints | `AreaBalancePowerModel`: one row per region |
# | 6 | Branches | `ModelConstructStage` | flow limits | interchange limits |
# | 7 | Services | `ModelConstructStage` | service constraints | `FCASMarket` joint rows, `LinearFactorLimit` rows |
# | 8 | Objective | `update_objective_function!` | sum of every cost term | offers and FCAS offers |

# The same pipeline, coloured by who supplies the code at each phase:

function plot_phases()
    fig = Figure(size = (1000, 330))
    ax = Axis(fig[1, 1]; yreversed = true, backgroundcolor = :transparent)
    hidedecorations!(ax); hidespines!(ax)
    xlims!(ax, -0.1, 9.8); ylims!(ax, 2.4, -0.1)
    colors = Makie.wong_colors()
    shapes = [
        ("1", "Devices", "arguments", true), ("2", "Services", "arguments", true),
        ("3", "Branches", "arguments", false), ("4", "Devices", "model", true),
        ("5", "Network", "model", false), ("6", "Branches", "model", false),
        ("7", "Services", "model", true), ("8", "Objective", "assembly", false),
    ]
    for (i, (number, title, stage, aemsim)) in enumerate(shapes)
        x = (i - 1) * 1.2
        color = aemsim ? colors[2] : colors[1]
        poly!(ax, Rect2f(x, 0.2, 1.05, 1.3); color = (color, 0.55), strokecolor = color, strokewidth = 2)
        text!(ax, x + 0.52, 0.5; text = number, align = (:center, :center), fontsize = 22, font = :bold)
        text!(ax, x + 0.52, 0.95; text = title, align = (:center, :center), fontsize = 13)
        text!(ax, x + 0.52, 1.2; text = stage, align = (:center, :center), fontsize = 12, color = (:gray, 1.0))
        i < length(shapes) && arrows2d!(ax, [x + 1.06], [0.85], [0.13], [0.0]; color = :gray)
    end
    poly!(ax, Rect2f(0.0, 1.85, 0.25, 0.2); color = (colors[2], 0.55), strokecolor = colors[2], strokewidth = 2)
    text!(ax, 0.35, 1.95; text = "methods AEMSim adds (NEMReplayDispatch, FCASMarket, LinearFactorLimit)", align = (:left, :center), fontsize = 13)
    poly!(ax, Rect2f(5.6, 1.85, 0.25, 0.2); color = (colors[1], 0.55), strokecolor = colors[1], strokewidth = 2)
    text!(ax, 5.95, 1.95; text = "provided by PowerSimulations.jl", align = (:left, :center), fontsize = 13)
    return fig
end
plot_phases()

# AEMSim's contribution is a set of methods on these hooks. They can be listed from the
# method table, which shows the dispatch pairs the template selected:

strip_modules(x) = replace(string(x), r"\b(?:[A-Z][A-Za-z]*\.)+" => "")

function hooks(f, needle)
    rows = NamedTuple{(:hook, :stage, :model_type), Tuple{String, String, String}}[]
    for m in methods(f)
        params = Base.unwrap_unionall(m.sig).parameters
        any(p -> occursin(needle, string(p)), params) || continue
        stage_index = findfirst(p -> occursin("ConstructStage", string(p)), params)
        isnothing(stage_index) && continue
        model_params = Base.unwrap_unionall(params[stage_index + 1]).parameters
        bound(p) = p isa TypeVar ? p.ub : p
        model_type = join(strip_modules.(bound.(model_params)), " / ")
        push!(rows, (; hook = string(nameof(f)), stage = replace(strip_modules(params[stage_index]), "ConstructStage" => ""), model_type))
    end
    return sort!(DataFrame(rows), :stage)
end
vcat(
    hooks(PSI.construct_device!, "AbstractNEMDispatch"),
    hooks(PSI.construct_service!, "FCASMarket"),
    hooks(PSI.construct_service!, "LinearFactorLimit"),
)

# ### Step 4: the formulation, in a few methods
#
# Each AEMSim formulation is a type plus methods. The type tree is small:

subtypes(AbstractNEMDispatch)

# Choosing `NEMReplayDispatch` over `NEMLookaheadDispatch` is a different *type*, and so a
# different method: the lookahead variant measures the first ramp against a solved initial
# condition and later ramps against the previous interval's variable, instead of the
# `"initial_mw"` series. Which series the formulation reads is itself declared through
# dispatch, so a template can verify the `System` carries what the formulation will need:

PSI.get_default_time_series_names(PSY.ThermalStandard, NEMReplayDispatch)

# Variable bounds and the objective multiplier are traits, one-line methods on the same pair:

PSI.get_variable_lower_bound(PSI.ActivePowerVariable(), PSY.get_component(PSY.ThermalStandard, sys, "COAL1"), NEMReplayDispatch())

# and the bid stack reaches the objective through PSI's own market-bid cost path, which is why
# the `MarketBidCost` attached in Step 1 is all the formulation needs to price a unit.
#
# ### Step 5: build, inspect, solve

model_psi = PSI.DecisionModel(
    template, sys;
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
    horizon = RESOLUTION, resolution = RESOLUTION, interval = RESOLUTION,
    initial_time = T0, name = "intro_to_psi_nem", store_variable_names = true,
)
build_status = PSI.build!(model_psi; output_dir = mktempdir())

# The container now holds typed, named pieces of the problem we wrote by hand:

container = PSI.get_optimization_container(model_psi)
jump_psi = PSI.get_jump_model(container)

function container_summary(container)
    kinds = (
        "variables" => PSI.get_variables(container), "expressions" => PSI.get_expressions(container),
        "parameters" => PSI.get_parameters(container), "constraints" => PSI.get_constraints(container),
    )
    return DataFrame(
        kind = [k for (k, _) in kinds],
        keys = [length(d) for (_, d) in kinds],
        entries = [
            join(unique([string(nameof(PSI.IS.Optimization.get_entry_type(k))) for k in keys(d)]), ", ")
                for (_, d) in kinds
        ],
    )
end
container_summary(container)

# Each object of Part 1 has a typed home in the container, addressed by *(entry type,
# component type, meta)* rather than by a variable name:
#
# | Part 1 (JuMP) | PSI container key | Built by |
# | --- | --- | --- |
# | `dispatch[u]` | variable `ActivePowerVariable`, per component type | `NEMReplayDispatch`, argument stage |
# | `band[u, b]`, bid-stack cost | variable `PiecewiseLinearBlockIncrementalOffer`, constraint of the same name, `ProductionCostExpression` | PSI's market-bid cost path, called from `NEMReplayDispatch` |
# | `availability[u]` | constraint `ActivePowerVariableTimeSeriesLimitsConstraint`, parameter `ActivePowerTimeSeriesParameter` | `NEMReplayDispatch`, model stage |
# | `ramp_up[u]`, `ramp_down[u]` | constraint `RampConstraint` (meta `up`/`down`), parameters `RampUp/DownRateTimeSeriesParameter`, `InitialPowerTimeSeriesParameter` | `NEMReplayDispatch`, model stage |
# | `balance_nsw`, `balance_vic` | constraint `CopperPlateBalanceConstraint` on `Area`, expression `ActivePowerBalance` | PSI network model |
# | `flow` | variable `FlowActivePowerVariable`, constraint `FlowLimitConstraint` | PSI branch model |
# | `raise[u]` | variable `FCASCapacityVariable` (meta: the service) | `FCASMarket`, argument stage |
# | trapezium rows | expression `FCASJointCapacityLHS`, constraint `FCASJointCapacityConstraint` (meta `..._upper`/`..._lower`) | `FCASMarket`, both stages |
# | `coal_limit` | expression `NEMConstraintLHS`, constraint `NEMConstraintLimit`, parameter `NEMConstraintRHSParameter` | `LinearFactorLimit` |
#
# The mapping is checked, not assumed: every key above must exist in the built container.

expected_keys = [
    (PSI.ActivePowerVariable, PSY.ThermalStandard, ""),
    (PSI.ActivePowerVariable, PSY.RenewableDispatch, ""),
    (PSI.PiecewiseLinearBlockIncrementalOffer, PSY.ThermalStandard, ""),
    (PSI.FlowActivePowerVariable, PSY.AreaInterchange, ""),
    (FCASCapacityVariable, FCASService, "NSW1_RAISE6SEC"),
]
all(
    PSI.has_container_key(container, entry, component, meta) for (entry, component, meta) in expected_keys
)

# ### The FCAS requirement
#
# `FCASMarket` builds the per-unit FCAS capacity variables, the trapezium joint rows and the
# offer cost. What it does **not** yet build is the regional *requirement*: AEMO publishes it
# as a generic constraint, and the formulation that lets a `GenericConstraint` carry FCAS
# terms is not merged (see [What is not here yet](@ref intro-psi-gaps)). Until then the
# requirement row is added directly to the built JuMP model, on the capacity variables the
# service formulation created, which is exactly what an FCAS term would produce:

requirement_rows = Dict{String, JuMP.ConstraintRef}()
for region in ("NSW1", "VIC1")
    capacity = PSI.get_variable(container, FCASCapacityVariable(), FCASService, "$(region)_RAISE6SEC")
    providers = [String(u) for u in keys(fcas) if fcas[u].region == region]
    requirement_rows[region] = JuMP.@constraint(
        jump_psi, sum(capacity[u, 1] for u in providers) >= requirement[Symbol(region)] / BASE_POWER,
    )
end

solve_status = PSI.solve!(model_psi)

# ### Step 6: read the results and check them against Part 1
#
# Variables are in MW, duals are per unit of the system base and per interval, so
# `dual / (base_power * interval_hours)` converts them to `\$/MWh` (AEMSim exports the
# interval length in hours as `DISPATCH_INTERVAL_HOURS`).

results = PSI.OptimizationProblemResults(model_psi)
to_dollars_per_mwh(dual) = dual / (BASE_POWER * DISPATCH_INTERVAL_HOURS)

function value_by_name(df)
    return Dict(Symbol(r.name) => r.value for r in eachrow(df))
end
psi_dispatch = merge(
    value_by_name(read_variable(results, "ActivePowerVariable__ThermalStandard")),
    value_by_name(read_variable(results, "ActivePowerVariable__RenewableDispatch")),
)
psi_price = Dict(
    r.name => to_dollars_per_mwh(r.value) for r in eachrow(read_dual(results, "CopperPlateBalanceConstraint__Area"))
)
psi_flow = only(read_variable(results, "FlowActivePowerVariable__AreaInterchange").value)
psi_fcas_price = Dict(r => to_dollars_per_mwh(JuMP.dual(row)) for (r, row) in requirement_rows)
coal_dual_key = only(k for k in keys(read_duals(results)) if occursin("N_COAL_LIMIT", k))
psi_limit_price = to_dollars_per_mwh(only(read_dual(results, coal_dual_key).value))
psi_objective = JuMP.objective_value(jump_psi)

comparison = DataFrame(
    quantity = [
        "COAL1 energy (MW)", "WIND1 energy (MW)", "GAS1 energy (MW)", "Flow NSW1 to VIC1 (MW)",
        "NSW1 energy price (\$/MWh)", "VIC1 energy price (\$/MWh)",
        "NSW1 RAISE6SEC price (\$/MW/h)", "VIC1 RAISE6SEC price (\$/MW/h)",
        "N_COAL_LIMIT marginal value (\$/MWh)", "Objective (\$)",
    ],
    hand_written_JuMP = [
        constrained.dispatch[:COAL1], constrained.dispatch[:WIND1], constrained.dispatch[:GAS1], constrained.flow,
        constrained.price["NSW1"], constrained.price["VIC1"],
        constrained.fcas_price["NSW1"], constrained.fcas_price["VIC1"], constrained.limit_price, constrained.objective,
    ],
    PSI_with_AEMSim = [
        psi_dispatch[:COAL1], psi_dispatch[:WIND1], psi_dispatch[:GAS1], psi_flow,
        psi_price["NSW1"], psi_price["VIC1"], psi_fcas_price["NSW1"], psi_fcas_price["VIC1"],
        psi_limit_price, psi_objective,
    ],
)
comparison.difference = comparison.PSI_with_AEMSim .- comparison.hand_written_JuMP
comparison

# Both models are the same linear programme, so they must agree. The objective and every
# dispatch, flow and price match to solver tolerance, which is the point of this page:
# the AEMSim formulations reproduce what the JuMP model of Part 1 states by hand.

@assert build_status == PSI.ModelBuildStatus.BUILT
@assert solve_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED
@assert maximum(abs, comparison.difference) < 1.0e-4

# The comparison covers the full model, with the FCAS requirement and the generic constraint
# active. The two JuMP models differ in size because PSI registers each row under a typed key
# and adds plumbing the hand-written model does not need: unserved-energy slacks on every
# regional balance, a band-sum constraint per unit, and parameter containers that
# hold the time-series values:

DataFrame(
    model = ["hand-written JuMP (Part 1)", "PSI container (Part 2)"],
    variables = [num_variables(model), num_variables(jump_psi)],
    constraints = [
        num_constraints(model; count_variable_in_set_constraints = false),
        num_constraints(jump_psi; count_variable_in_set_constraints = false),
    ],
)

# ## What the pieces are, and where they live
#
# Reading the page from the top, three layers did the work:
#
# - **AEM** (`AustralianElectricityMarkets`) turned market facts into `System` data: the
#   `FCASService`, `FCASTrapezium`/`FCASBid`, `GenericConstraint` and the time-series
#   contract (`"initial_mw"`, `"ramp_up_rate"`, `"max_active_power"`, `"variable_cost"`). It
#   knows nothing about JuMP.
# - **PSI** (`PowerSimulations.jl`) owns the build order, the `OptimizationContainer`, the
#   regional network model and the objective assembly. It knows nothing about the NEM.
# - **AEMSim** (`AustralianElectricityMarketsSimulations`) is the glue: formulation types
#   (`NEMReplayDispatch`, `FCASMarket`, `LinearFactorLimit`) and the methods PSI calls on them
#   at each stage. It is the only package that mentions both.
#
# This split is why swapping a study's data (a different interval, a different network
# configuration, a battery in place of a thermal unit) changes a `System`, not the model code,
# and why a new market rule becomes a new formulation method rather than a rewrite.

# ## [What is not here yet](@id intro-psi-gaps)
#
# AEMSim reproduces the dispatch of this page, but the PSI extension does not yet cover all of
# NEMDE. Compared with the hand-written model, the pieces still to land are:
#
# - **FCAS requirements as generic-constraint terms.** The regional requirement row above was
#   added by hand. The planned `GenericConstraint` formulation resolves FCAS terms to the
#   `FCASCapacityVariable` of the right service and reads FCAS prices off the constraint duals.
# - **Elastic constraints.** Both models here are strictly feasible. NEMDE's generic
#   constraints carry a violation penalty (the constraint violation penalty factors) so
#   infeasible sets still solve; the `use_slacks` penalty in the PSI network model is PSI's
#   own unserved-energy slack, not NEMDE's schedule of penalties.
# - **Interconnector losses.** The `AreaInterchange` flow here is lossless. AEM already
#   stores a loss model on the interconnector, but the PSI formulation that splits losses
#   between the two regional balances is still in review.
# - **Multi-interval problems.** `NEMReplayDispatch` is built for single intervals measured
#   from `"initial_mw"`; `NEMLookaheadDispatch` chains intervals through variables and an
#   initial condition, and `FCASMarket` currently supports a standalone `DecisionModel` only.
#
# See [Roadmap](@ref) for the planned order.

# ## [References](@id intro-psi-references)
#
# - AEMO, [*FCAS Model in NEMDE*](https://nempy.readthedocs.io/en/latest/_downloads/e3c8a21d3084db332a30bd0d564e93c3/FCAS%20Model%20in%20NEMDE.pdf):
#   the trapezium (§2-3), joint constraints and prices.
# - AEMO, [*Guide to Ancillary Services in the National Electricity Market*](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/ancillary_services/guide-to-ancillary-services-in-the-national-electricity-market.pdf).
# - AEMO, [*NEMDE queue and dispatch process*](https://www.aemo.com.au/energy-systems/electricity/national-electricity-market-nem/system-operations/dispatch).
# - [PowerSimulations.jl documentation](https://nrel-sienna.github.io/PowerSimulations.jl/stable/):
#   `ProblemTemplate`, `DecisionModel`, and the extension points (device, service and network
#   formulations) used by AEMSim.
# - [PowerSystems.jl documentation](https://nrel-sienna.github.io/PowerSystems.jl/stable/):
#   `System`, components, time series and supplemental attributes.
# - [JuMP documentation](https://jump.dev/JuMP.jl/stable/).
