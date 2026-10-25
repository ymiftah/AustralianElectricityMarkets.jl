begin
    using JuMP
    using HiGHS
    using DataFrames
    using CairoMakie
    using Markdown
end;

include(joinpath(@__DIR__, "..", "..", "literate", "shared", "toy_market.jl")) #hide
include(joinpath(@__DIR__, "..", "..", "literate", "shared", "toy_jump.jl")); #hide

# # [NEMDE as a JuMP model](@id nemde-jump)
#
# The [formulation overview](@ref nemde-model) introduces the full model. This page turns
# a deliberately reduced subset into running code: a [JuMP](https://jump.dev) model of a small market, solved with
# [HiGHS](https://highs.dev). Nothing here depends on `PowerSystems.jl` or `PowerSimulations.jl`;
# the next two pages show how to solve the toy market with those packages.
#
# !!! note "Example scope"
#     This teaching model omits scheduled consumption, batteries, regulation FCAS scaling,
#     fast-start profiles and price processing. Its piecewise loss curve is a toy approximation.
#     See the [formulation overview](@ref nemde-model) for the wider market formulation.
#
# ## The toy market
#
# Two regions joined by one interconnector with losses. `COAL1` (thermal) and `WIND1`
# (semi-scheduled, with a forecast `UIGF`) sit in `NSW1`; `GAS1` (thermal) sits in `VIC1`. Both
# thermal units also offer `RAISE6SEC` FCAS. Three generic constraints complete the market: a
# stability limit on `COAL1` and one `RAISE6SEC` requirement per region. A single 5-minute
# dispatch interval is cleared.
#
# The table shows each unit's availability, metered initial output, ramp capability and offers.

DataFrame(
    unit = [String(unit_name(u)) for u in market.units],
    region = [region(u) for u in market.units],
    availability_MW = availability.(market.units),
    initial_MW = initial_mw.(market.units),
    ramp_up_MW_per_interval = ramp_up.(market.units),
    bands = [join(["$(quantity(b)) MW @ \$$(price(b))" for b in bids(u)], ", ") for u in market.units],
)

# `WIND1` offers 200 MW at \$0 but its forecast is 150 MW, so only 150 MW of its offer is usable:
# the first place a forecast changes the bid stack. The merit order of each region, with the
# unusable part of the wind offer drawn faded:

region_colors = Dict(unit_name(u) => c for (u, c) in zip(market.units, Makie.wong_colors()))

function merit_order(region_name)
    steps = [(u = u, b = b) for u in units_in(market, region_name) for b in bids(u)]
    sort!(steps; by = s -> price(s.b))
    return steps
end

function plot_merit_order!(ax, region_name; cleared = nothing, clearing_price = nothing)
    left = 0.0
    used = Dict(unit_name(u) => availability(u) for u in market.units)
    for s in merit_order(region_name)
        usable = min(quantity(s.b), used[unit_name(s.u)])
        used[unit_name(s.u)] -= usable
        height = max(price(s.b), 3.0)
        color = region_colors[unit_name(s.u)]
        poly!(
            ax, Rect2f(left, 0.0, usable, height);
            color = (color, 0.8), strokecolor = color, strokewidth = 1,
        )
        if usable < quantity(s.b)
            poly!(
                ax, Rect2f(left + usable, 0.0, quantity(s.b) - usable, height);
                color = (color, 0.15), strokecolor = color, strokewidth = 1, linestyle = :dash,
            )
        end
        left += quantity(s.b)
    end
    isnothing(cleared) || vlines!(ax, cleared; color = :white, linestyle = :dash)
    isnothing(clearing_price) || hlines!(ax, clearing_price; color = :tomato, linestyle = :dot)
    return nothing
end

function merit_order_legend!(fig, position)
    return Legend(
        fig[position...],
        [PolyElement(color = region_colors[unit_name(u)]) for u in market.units],
        [String(unit_name(u)) for u in market.units];
        orientation = :horizontal, tellheight = true,
    )
end

let
    fig = Figure(size = (900, 340))
    for (i, r) in enumerate(market.regions)
        ax = Axis(fig[1, i]; title = r, xlabel = "Cumulative offered MW", ylabel = "Offer price (\$/MWh)")
        plot_merit_order!(ax, r)
        ylims!(ax, 0, 260)
    end
    merit_order_legend!(fig, (2, 1:2))
    fig
end

# ## Energy: bands, ramps and regional balance
#
# The decision variables are the MW cleared in each band of each offer, bounded by the band
# quantity. A unit's dispatch is the sum of its bands, and the objective is the offer cost over
# the interval of ``\Delta = 5/60`` hours.

model = Model(HiGHS.Optimizer)
set_silent(model)

@variable(model, 0 <= cleared[u in market.units, j in 1:n_bids(u)] <= quantity(bid(u, j)))
@expression(model, dispatch[u in market.units], sum(cleared[u, j] for j in 1:n_bids(u)))
@expression(model, offer_cost, sum(price(bid(u, j)) * cleared[u, j] * INTERVAL_H for u in market.units for j in 1:n_bids(u)))
@objective(model, Min, offer_cost)

# Each unit's dispatch is limited by its availability (the `UIGF` cap for `WIND1` is inside
# `availability`) and by what it can reach in one interval from `INITIALMW`:

@constraint(model, availability_limit[u in market.units], dispatch[u] <= availability(u))
@constraint(model, ramp_up_limit[u in market.units], dispatch[u] - initial_mw(u) <= ramp_up(u))
@constraint(model, ramp_down_limit[u in market.units], initial_mw(u) - dispatch[u] <= ramp_down(u))

# ### The interconnector and its losses
#
# The flow is a signed variable. The loss curve is linearised on the breakpoints: the flow is the
# first breakpoint plus the flow allocated to each segment, the loss is the loss at the first
# breakpoint plus each segment's slope times its flow, and a binary per segment boundary forces the
# segments to fill in order, so the solved loss follows the curve.
#
# !!! note "Toy loss curve"
#     This example uses five segments and binary variables to keep the solved flow and loss
#     on the chosen curve, including at negative prices. This construction is specific to the
#     example; it does not describe NEMDE's loss solution procedure.

ic = market.interconnector
segments = linearised_losses(ic)

@variable(model, flow)
@variable(model, 0 <= segment_flow[s in eachindex(segments)] <= segments[s].to_mw - segments[s].from_mw)
@variable(model, filled[s in 1:(length(segments) - 1)], Bin)
@expression(model, loss, loss_at(ic, ic.breakpoints[1]) + sum(segments[s].slope * segment_flow[s] for s in eachindex(segments)))

@constraint(model, flow_definition, flow == ic.breakpoints[1] + sum(segment_flow))
@constraint(model, segment_full[s in 1:(length(segments) - 1)], segment_flow[s] >= (segments[s].to_mw - segments[s].from_mw) * filled[s])
@constraint(model, segment_next[s in 1:(length(segments) - 1)], segment_flow[s + 1] <= (segments[s + 1].to_mw - segments[s + 1].from_mw) * filled[s])
@constraint(model, flow_limit_up, flow <= ic.max_flow)
@constraint(model, flow_limit_down, flow >= -ic.max_flow)

# ### Regional balance and prices
#
# Each region supplies its demand plus the flow it exports plus its share of the losses. The
# regional price is the dual of this row: the cost of one more MW of demand there.

generation(r) = sum(dispatch[u] for u in units_in(market, r))
exported(r) = r == ic.from ? flow : -flow
loss_charged(r) = (r == ic.from ? ic.from_loss_share : 1 - ic.from_loss_share) * loss

@constraint(model, balance[r in market.regions], generation(r) - exported(r) - loss_charged(r) == region_demand(market, r))

# ### Solving
#
# The segment binaries make this a small MILP. NEMDE prices come from the LP, so after the first
# solve the binaries are fixed at their solution and the LP is solved again to read the duals.
# Duals are per MW per interval; dividing by ``\Delta`` gives \$/MWh.

function solve!(model)
    optimize!(model)
    @assert termination_status(model) == OPTIMAL
    undo = fix_discrete_variables(model)
    optimize!(model)
    @assert termination_status(model) == OPTIMAL
    result = (;
        dispatch = Dict(unit_name(u) => value(model[:dispatch][u]) for u in market.units),
        flow = value(model[:flow]),
        loss = value(model[:loss]),
        price = Dict(r => dual(model[:balance][r]) / INTERVAL_H for r in market.regions),
        objective = objective_value(model),
        raise = haskey(model, :raise) ? Dict(unit_name(u) => value(model[:raise][u]) for u in fcas_units(market)) : nothing,
        generic = haskey(model, :generic) ? Dict(n => dual(c) / INTERVAL_H for (n, c) in model[:generic]) : nothing,
        violation = haskey(model, :violation) ? Dict(n => value(v) for (n, v) in model[:violation]) : nothing,
    )
    undo()
    return result
end

energy_only = solve!(model)

# The cheap `NSW1` coal and wind export up to the interconnector limit and the two prices
# separate: the congestion rent. The loss is charged half to each region.

DataFrame(
    quantity = [
        "COAL1 (MW)", "WIND1 (MW)", "GAS1 (MW)", "Flow NSW1 to VIC1 (MW)", "Loss (MW)",
        "NSW1 price (\$/MWh)", "VIC1 price (\$/MWh)", "Cost (\$)",
    ],
    value = [
        energy_only.dispatch[:COAL1], energy_only.dispatch[:WIND1], energy_only.dispatch[:GAS1],
        energy_only.flow, energy_only.loss, energy_only.price["NSW1"], energy_only.price["VIC1"],
        energy_only.objective,
    ],
)

# Each region's cleared quantity (demand plus exports plus its loss share) against its merit
# order and price:

function plot_clearing(result)
    fig = Figure(size = (900, 380))
    for (i, r) in enumerate(market.regions)
        ax = Axis(
            fig[1, i]; title = "$r (price \$$(round(result.price[r]; digits = 1))/MWh)",
            xlabel = "Cumulative offered MW", ylabel = "Offer price (\$/MWh)",
        )
        cleared_mw = sum(result.dispatch[unit_name(u)] for u in units_in(market, r))
        plot_merit_order!(ax, r; cleared = cleared_mw, clearing_price = result.price[r])
        ylims!(ax, 0, 260)
    end
    merit_order_legend!(fig, (2, 1:2))
    Label(fig[0, :], "Dashed: MW cleared in the region; dotted: regional price"; tellwidth = false)
    return fig
end
plot_clearing(energy_only)

# ## FCAS: the trapezium
#
# Each unit offering `RAISE6SEC` gets a capacity variable, the sum of its FCAS bands, and two
# *joint* rows that keep that capacity inside the unit's trapezium at its energy dispatch, so
# energy and FCAS compete for the same MW. The FCAS offer cost joins the objective.

DataFrame(
    unit = [String(unit_name(u)) for u in fcas_units(market)],
    enablement_min = [trapezium(u).enablement_min for u in fcas_units(market)],
    low_breakpoint = [trapezium(u).low_breakpoint for u in fcas_units(market)],
    high_breakpoint = [trapezium(u).high_breakpoint for u in fcas_units(market)],
    enablement_max = [trapezium(u).enablement_max for u in fcas_units(market)],
    max_avail = [max_avail(trapezium(u)) for u in fcas_units(market)],
    upper_slope = [upper_slope(trapezium(u)) for u in fcas_units(market)],
    lower_slope = [lower_slope(trapezium(u)) for u in fcas_units(market)],
)

@variable(model, 0 <= raise[u in fcas_units(market)] <= max_avail(trapezium(u)))
@variable(model, 0 <= raise_cleared[u in fcas_units(market), j in 1:n_fcas_bids(u)] <= quantity(fcas_bid(u, j)))
@constraint(model, raise_definition[u in fcas_units(market)], raise[u] == sum(raise_cleared[u, j] for j in 1:n_fcas_bids(u)))
@constraint(model, trapezium_upper[u in fcas_units(market)], dispatch[u] + upper_slope(trapezium(u)) * raise[u] <= trapezium(u).enablement_max)
@constraint(model, trapezium_lower[u in fcas_units(market)], dispatch[u] - lower_slope(trapezium(u)) * raise[u] >= trapezium(u).enablement_min)
@expression(model, fcas_cost, sum(price(fcas_bid(u, j)) * raise_cleared[u, j] * INTERVAL_H for u in fcas_units(market) for j in 1:n_fcas_bids(u)))
set_objective_function(model, objective_function(model) + fcas_cost)

# ## Generic constraints
#
# Both the `RAISE6SEC` requirements and the network limit are *generic constraints*: a linear
# combination of unit energy, unit FCAS and interconnector flow, a sense and a right-hand side.
# Each toy constraint carries a violation variable, paid at its penalty factor times the
# Market Price Cap. This follows the violation-priority principle in AEMO's *Schedule of
# Constraint Violation Penalty Factors* (§1, pp. 3-4). For each independent, unit-coefficient
# FCAS requirement here, the dual divided by the interval duration gives its FCAS price.

model[:generic] = Dict{String, ConstraintRef}()
model[:violation] = Dict{String, VariableRef}()

function term_variable(model, t::Term)
    t.kind == :energy && return model[:dispatch][find_unit(market, t.id)]
    t.kind == :raise6 && return model[:raise][find_unit(market, t.id)]
    return model[:flow]
end

function add_generic_constraint!(model, gc::LinearConstraint)
    lhs = sum(t.factor * term_variable(model, t) for t in gc.terms)
    violation = @variable(model, lower_bound = 0, base_name = "violation_$(gc.name)")
    model[:generic][gc.name] = if gc.sense == :LE
        @constraint(model, lhs - violation <= gc.rhs)
    else
        @constraint(model, lhs + violation >= gc.rhs)
    end
    model[:violation][gc.name] = violation
    set_objective_function(model, objective_function(model) + gc.weight * MARKET_PRICE_CAP * INTERVAL_H * violation)
    return nothing
end

# First the FCAS requirements:

foreach(gc -> add_generic_constraint!(model, gc), filter(gc -> startswith(gc.name, "F_"), market.constraints))
co_optimised = solve!(model)

# Co-optimisation changes the *energy* outcome. `NSW1` has to hold 40 MW of `RAISE6SEC` on the
# coal unit; at 400 MW of energy the trapezium only lets it offer 30 MW, so energy is pushed
# down until the joint row is satisfied. That removes cheap export, the interconnector comes off
# its limit and the gap between the two regional prices shrinks to the cost of marginal losses. The FCAS price is not the \$8/MW/h of the
# marginal FCAS offer: it also contains the energy the coal unit gives up.

# The coal unit's trapezium in the energy and FCAS plane: every `(energy, FCAS)` pair the unit may
# be dispatched at is in the shaded area; the markers are where the solves put it.

function plot_trapezium!(ax, t::Trapezium, points)
    poly!(
        ax, Point2f[
            (t.enablement_min, 0), (t.low_breakpoint, t.max_avail),
            (t.high_breakpoint, t.max_avail), (t.enablement_max, 0),
        ];
        color = (Makie.wong_colors()[1], 0.35), strokecolor = Makie.wong_colors()[1], strokewidth = 2,
    )
    for (label, energy, fcas, marker) in points
        scatter!(ax, energy, fcas; markersize = 14, marker, label)
    end
    return nothing
end

let
    fig = Figure(size = (900, 360))
    for (i, u) in enumerate(fcas_units(market))
        ax = Axis(fig[1, i]; title = "$(unit_name(u)) RAISE6SEC", xlabel = "Energy dispatch (MW)", ylabel = "RAISE6SEC (MW)")
        plot_trapezium!(
            ax, trapezium(u), [
                ("energy only", energy_only.dispatch[unit_name(u)], 0.0, :diamond),
                ("co-optimised", co_optimised.dispatch[unit_name(u)], co_optimised.raise[unit_name(u)], :circle),
            ],
        )
        i == 1 && axislegend(ax; position = :lb)
    end
    fig
end

# Finally the network limit on the coal unit, just below where co-optimisation left it (383 MW).
# The limit binds: gas replaces the coal it caps, and the limit's dual is the cost of that
# replacement per MW.

foreach(gc -> add_generic_constraint!(model, gc), filter(gc -> !startswith(gc.name, "F_"), market.constraints))
constrained = solve!(model)

# ## Results
#
# One table for the three stages. The dual of `N_COAL_LIMIT` is negative: one more MW of headroom
# would lower the cost by that amount.

results_table = DataFrame(
    quantity = [
        "COAL1 (MW)", "WIND1 (MW)", "GAS1 (MW)", "Flow NSW1 to VIC1 (MW)", "Loss (MW)",
        "NSW1 price (\$/MWh)", "VIC1 price (\$/MWh)",
        "NSW1 RAISE6SEC price (\$/MW/h)", "VIC1 RAISE6SEC price (\$/MW/h)",
        "N_COAL_LIMIT dual (\$/MWh)", "Objective (\$)",
    ],
    energy_only = [
        energy_only.dispatch[:COAL1], energy_only.dispatch[:WIND1], energy_only.dispatch[:GAS1],
        energy_only.flow, energy_only.loss, energy_only.price["NSW1"], energy_only.price["VIC1"],
        NaN, NaN, NaN, energy_only.objective,
    ],
    with_fcas = [
        co_optimised.dispatch[:COAL1], co_optimised.dispatch[:WIND1], co_optimised.dispatch[:GAS1],
        co_optimised.flow, co_optimised.loss, co_optimised.price["NSW1"], co_optimised.price["VIC1"],
        co_optimised.generic["F_NSW_R6"], co_optimised.generic["F_VIC_R6"], NaN, co_optimised.objective,
    ],
    with_fcas_and_limit = [
        constrained.dispatch[:COAL1], constrained.dispatch[:WIND1], constrained.dispatch[:GAS1],
        constrained.flow, constrained.loss, constrained.price["NSW1"], constrained.price["VIC1"],
        constrained.generic["F_NSW_R6"], constrained.generic["F_VIC_R6"],
        constrained.generic["N_COAL_LIMIT"], constrained.objective,
    ],
)

# No constraint was violated: every violation variable is zero, so the penalties only shape the
# problem when something is infeasible.

maximum(abs, values(constrained.violation))

# The loss curve with its linearisation and the solved flows:

let
    fig = Figure(size = (900, 320))
    ax = Axis(fig[1, 1]; xlabel = "Flow NSW1 to VIC1 (MW)", ylabel = "Loss (MW)", title = "Interconnector loss")
    flows = range(-ic.max_flow, ic.max_flow; length = 101)
    lines!(ax, flows, loss_at.(Ref(ic), flows); label = "quadratic loss")
    bp = ic.breakpoints
    lines!(ax, bp, loss_at.(Ref(ic), bp); linestyle = :dash, label = "linearisation")
    for (label, r, marker) in (("energy only", energy_only, :diamond), ("with FCAS and limit", constrained, :circle))
        scatter!(ax, r.flow, r.loss; markersize = 14, marker, label)
    end
    axislegend(ax; position = :ct)
    fig
end

# This completes the dispatch model for the toy market: an offer-cost objective, unit envelopes,
# regional balance with a lossy interconnector, the FCAS trapezium and generic constraints with
# violation penalties. The [next page](@ref nemde-psi) solves the energy-only, lossless
# version using PowerSimulations.jl.

# Compare the dispatch and prices with the reference toy solution:

reference = solve_toy_jump(market)
@assert maximum(abs, [constrained.dispatch[u] - reference.dispatch[u] for u in keys(reference.dispatch)]) < 1.0e-6
@assert abs(constrained.objective - reference.objective) < 1.0e-6
