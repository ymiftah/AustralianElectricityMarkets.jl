begin
    using CairoMakie
end;

# # [The NEMDE model](@id nemde-model)
#
# This page describes the optimisation problem that decides who
# generates what in Australia's National Electricity Market. By the end a reader
# should know every family of equations that governs the dispatch.
#
# !!! note "Sources"
#     The equations follow AEMO's published documents: *FCAS Model in NEMDE* (the trapezium and
#     its scaling), *Fast Start Inflexibility Profile*, *Marginal Loss Factors* (the interconnector
#     loss equations), *Schedule of Constraint Violation Penalty Factors* and the *Constraint
#     Formulation Guidelines*. AEMO does not publish the solver itself, so this is the problem
#     as documented, not a transcription of NEMDE's code. See [References](@ref nemde-model-references).
#
# ## What NEMDE is
#
# The NEM Dispatch Engine (NEMDE) is an optimisation problem, that AEMO solves every **5 minutes**. It chooses, for
# every scheduled and semi-scheduled unit, the MW to produce at the end of the coming dispatch
# interval, and in the same optimisation how much of ten *frequency control ancillary services*
# (FCAS) each unit holds in reserve. It minimises the total cost of the **offers** participants
# submitted, subject to the physical limits of the units and the network.
#
# | | |
# | --- | --- |
# | **Inputs** | offers (price-quantity bands), unit availability and forecasts, each unit's MW at the start of the interval (`INITIALMW`), ramp rates, regional demand forecasts, interconnector limits and loss models, FCAS requirements, and the *generic constraints* that describe the network |
# | **Outputs** | a dispatch target per unit, a flow per interconnector, FCAS enablement per unit, and the prices: the *dual values* of the regional balance and requirement constraints |
#


let
    fig = Figure(size = (900, 300))
    ax = Axis(
        fig[1, 1]; xlabel = "Minutes", ylabel = "Unit output (MW)",
        xticks = 0:5:15, title = "Three dispatch intervals for one unit",
    )
    initial = [420.0, 440.0, 455.0, 470.0]
    for k in 0:2
        lines!(ax, [5k, 5k + 5], initial[(k + 1):(k + 2)]; color = :tomato, linewidth = 3)
        vlines!(ax, 5k; color = (:gray, 0.6), linestyle = :dash)
    end
    vlines!(ax, 15; color = (:gray, 0.6), linestyle = :dash)
    scatter!(ax, [0, 5, 10], initial[1:3]; color = :white, markersize = 12, label = "INITIALMW (start of interval)")
    scatter!(ax, [5, 10, 15], initial[2:4]; color = :tomato, marker = :diamond, markersize = 12, label = "dispatch target (end of interval)")
    axislegend(ax; position = :rb)
    ylims!(ax, 400, 490)
    fig
end

# Every 5 minutes NEMDE receives the latest bid offers, forecasts and measured state, and returns the
# target the unit is asked to reach by the end of the interval. Each problem is a
# *single-interval* optimisation with the initial state as data.
#
# ### Notation
#
# | Symbol | Meaning |
# | --- | --- |
# | ``u``, ``r``, ``i`` | a unit, a region, an interconnector |
# | ``b`` | an offer band of a unit, ``b = 1, \dots, 10`` |
# | ``k`` | an FCAS service (`RAISE6SEC`, `LOWER5MIN`, ...) |
# | ``\Delta`` | the interval length in hours, ``5/60`` |
# | ``p_u`` | energy dispatch of unit ``u`` (MW) |
# | ``q_{u,b}`` | MW cleared in band ``b`` of unit ``u`` |
# | ``f_{u,k}`` | FCAS ``k`` enabled on unit ``u`` (MW) |
# | ``x_i`` | flow on interconnector ``i`` (MW), positive from its `from` region to its `to` region |
#
# ## Bids and the objective
#
# A unit does not report a cost function. It submits an **offer**: up to ten *bands*, each a
# quantity ``Q_{u,b}`` (MW) that it is willing to supply at a price ``\pi_{u,b}`` (\$/MWh) or
# more, with prices non-decreasing in ``b``. The dispatch of a unit is the sum of what is cleared
# in each band:
#
# ```math
# p_u = \sum_b q_{u,b}, \qquad 0 \le q_{u,b} \le Q_{u,b}
# ```
#
# Each unit also offers FCAS bands ``Q^{k}_{u,b}`` at prices ``\pi^{k}_{u,b}`` (\$/MW/h) for each
# service it can provide. Generic constraints and some physical limits can be violated at a
# penalty (below). The objective is the total cost of cleared offers plus the penalties:
#
# ```math
# \min \; \Delta \Big( \sum_{u,b} \pi_{u,b}\, q_{u,b} + \sum_{u,k,b} \pi^{k}_{u,b}\, q^{k}_{u,b} \Big)
# \; + \; \text{penalties}
# ```
#
# Because the objective minimises cost, bands are used in increasing price order, which gives the
# familiar **merit order**. When nothing else binds, the price in a region is the offer of the most
# expensive band dispatched there, its *marginal* band (AEMO, *Treatment of Loss Factors in the
# NEM*, worked example: the marginal generating unit sets the spot price at the regional reference
# node, with offers compared after loss factors).
#
# That is a special case. In general the regional price is the dual of the balance constraint
# (see below): the cost of serving one more MW of demand in that region, **including whatever
# re-dispatch binding constraints force**. A binding network or generic constraint can therefore
# make a unit run at an output its offer price alone would not justify, and the price it receives
# can be below its offer. AEMO describes this as a unit being *constrained on*: it "may be forced
# to generate energy at a power level which is more costly than the market return it receives for
# that energy"; a unit *constrained off* is held below the output its offers would earn at the
# price (AEMO, *Constraint Formulation Guidelines*, §1-2). The offer of a dispatched band is thus
# not always at or below the regional price, and the marginal band need not exist at all.

let
    bands = [
        ("wind", 150.0, 0.0), ("coal", 200.0, 25.0), ("coal", 150.0, 35.0),
        ("coal", 150.0, 55.0), ("gas", 100.0, 70.0), ("gas", 150.0, 110.0), ("gas", 150.0, 250.0),
    ]
    colors = Dict("wind" => Makie.wong_colors()[3], "coal" => Makie.wong_colors()[1], "gas" => Makie.wong_colors()[2])
    demand = 700.0
    fig = Figure(size = (900, 340))
    ax = Axis(fig[1, 1]; xlabel = "Cumulative offered MW", ylabel = "Offer price (\$/MWh)", title = "Merit order of one region")
    left = 0.0
    for (kind, q, price) in bands
        poly!(
            ax, Rect2f(left, 0.0, q, max(price, 3.0)); color = (colors[kind], 0.8),
            strokecolor = colors[kind], strokewidth = 1,
        )
        left += q
    end
    vlines!(ax, demand; color = :white, linestyle = :dash)
    hlines!(ax, 70.0; color = :tomato, linestyle = :dot)
    text!(ax, demand + 10, 200; text = "demand", align = (:left, :center))
    text!(ax, 20, 78; text = "price = marginal band (\$70)", align = (:left, :bottom), color = :tomato)
    Legend(
        fig[1, 2], [PolyElement(color = c) for c in values(colors)], collect(keys(colors));
        tellheight = false, tellwidth = true,
    )
    fig
end

# Here demand of 700 MW is met by the wind band, all three coal bands and the first 50 MW of the
# first gas band (the dashed line). With no binding constraint the price is the offer of the last
# band cleared (dotted line).
#
# ## Device constraints
#
# These constraints involve one unit (or one interconnector) at a time.
#
# ### Availability and the ramp envelope
#
# A unit can be dispatched no higher than what it declares available (``\text{AVAIL}_u``, its
# `MAXAVAIL` offer, or for a semi-scheduled unit the forecast, see below), and no further than it
# can *move in one interval from where it started*. With ``p^0_u`` the unit's `INITIALMW` and
# ``R^{\uparrow}_u``, ``R^{\downarrow}_u`` its ramp rates in MW/h (which may differ):
#
# ```math
# p_u \le \text{AVAIL}_u, \qquad
# p_u - p^0_u \le R^{\uparrow}_u \Delta, \qquad
# p^0_u - p_u \le R^{\downarrow}_u \Delta
# ```
#
# The result is an interval of reachable dispatch around the initial MW, clipped at the top by
# availability:

let
    initial, up, down, avail = 420.0, 600.0, 300.0, 440.0
    fig = Figure(size = (900, 320))
    ax = Axis(fig[1, 1]; xlabel = "Minutes into the interval", ylabel = "MW", title = "Reachable dispatch in one interval")
    t = [0.0, 5.0]
    ceiling = min.(avail, initial .+ up .* t ./ 60)
    floor_ = max.(0.0, initial .- down .* t ./ 60)
    band!(ax, t, floor_, ceiling; color = (Makie.wong_colors()[1], 0.35))
    lines!(ax, t, initial .+ up .* t ./ 60; color = Makie.wong_colors()[1], linestyle = :dash, label = "initial + up ramp")
    lines!(ax, t, floor_; color = Makie.wong_colors()[1], label = "initial - down ramp")
    hlines!(ax, avail; color = :tomato, label = "availability")
    scatter!(ax, 0.0, initial; color = :white, markersize = 12, label = "INITIALMW")
    axislegend(ax; position = :lt)
    ylims!(ax, 380, 480)
    fig
end

# Up and down ramp rates are separate data, and availability can clip the envelope (the dashed
# line is the ramp-only ceiling; the shaded region stops at availability).
#
# ### Fast start units
#
# A *fast start* unit (one that can synchronise and reach minimum load within 30 minutes) must
# follow a **dispatch inflexibility profile** it submits: times ``T_1`` to synchronise, ``T_2``
# to reach minimum load, ``T_3`` to remain at minimum load and ``T_4`` to shut down. NEMDE tracks
# the unit's *mode* (0 offline, 1 synchronising, 2 start-up, 3 minimum load, 4 normal operation)
# and the time already spent in it, and fixes or lower-bounds the dispatch accordingly: the unit
# is on fixed dispatch while synchronising and starting up (zero, then ramping to minimum load),
# in mode 4 the profile still lower-bounds dispatch while the time in mode is below ``T_4``, and
# afterwards it is dispatched like any other unit (AEMO, *Fast Start Inflexibility Profile*, Table 1).

let
    T = (5.0, 10.0, 15.0, 10.0)   # minutes: T1 to T4
    minload = 60.0
    ts = cumsum([0.0, T...])
    profile = [0.0, 0.0, minload, minload, 0.0]
    fig = Figure(size = (900, 300))
    ax = Axis(fig[1, 1]; xlabel = "Minutes since the dispatch instruction", ylabel = "MW", title = "Dispatch inflexibility profile")
    lines!(ax, ts, profile; color = :tomato, linewidth = 3)
    hlines!(ax, minload; color = (:gray, 0.6), linestyle = :dot)
    for (k, label) in enumerate(("T1: synchronise", "T2: to minimum load", "T3: at minimum load", "T4: shut down"))
        vlines!(ax, ts[k + 1]; color = (:gray, 0.6), linestyle = :dash)
        text!(ax, (ts[k] + ts[k + 1]) / 2, 8; text = label, align = (:center, :bottom), fontsize = 11)
    end
    ylims!(ax, -2, 80)
    fig
end

# Fast start and the discrete decisions it brings are the least linear part of the model.
#
# ### Interconnector limits
#
# An interconnector's flow is a signed variable bounded by its limits in each direction, which
# NEMDE takes from the published import and export limits:
#
# ```math
# -\bar X^{\leftarrow}_i \; \le \; x_i \; \le \; \bar X^{\rightarrow}_i
# ```
#
# Dynamic limits (thermal, stability) also appear as *generic constraints* involving the flow, and
# the static limit itself is *soft*: it can be violated at a penalty so that conflicting limits
# never make the problem infeasible.
#
# ### Interconnector losses
#
# Power flowing on an interconnector is partly lost. AEMO publishes, for each interconnector, a
# **loss factor** ``\mathrm{lf}_i`` that depends on the flow and on the demand of nearby regions
# ``D_r``, and the losses are the integral of ``\mathrm{lf} - 1``:
#
# ```math
# \mathrm{lf}_i(x) = c_i + a_i\, x + \sum_r d_{i,r}\, D_r, \qquad
# L_i(x) = \int_0^{x} \big(\mathrm{lf}_i(s) - 1\big)\, ds
# ```
#
# which is quadratic in the flow. NEMDE linearises ``L_i`` on a set of *breakpoints* of the flow
# (AEMO's loss models have between 60 and 120 of them per interconnector), so that the loss is the
# first breakpoint's loss plus a slope times the flow in each segment (a convex curve fills in
# order). The loss is split between the two regions in a fixed ratio ``s_i``
# (the share charged to the `from` region), entering both regional balances:
#
# ```math
# \sum_{u \in r} p_u - x_i - s_i L_i = D_r \;\; (r \text{ the } \text{from} \text{ region}), \qquad
# \sum_{u \in r'} p_u + x_i - (1 - s_i) L_i = D_{r'} \;\; (r' \text{ the } \text{to} \text{ region})
# ```
#
# The two regional prices then differ by the marginal loss, even when the interconnector is not
# congested. With ``m_i`` the slope of the loss segment the flow is on,
#
# ```math
# \lambda_{r'} \big(1 - (1 - s_i) m_i\big) = \lambda_r \big(1 + s_i m_i\big)
# ```

let
    c = 0.0006
    loss(x) = c / 2 * x^2
    bp = [-100.0, -60.0, -20.0, 20.0, 60.0, 100.0]
    x = range(-100, 100; length = 201)
    fig = Figure(size = (900, 300))
    ax = Axis(fig[1, 1]; xlabel = "Flow from region to region (MW)", ylabel = "Loss (MW)", title = "Interconnector loss curve")
    lines!(ax, x, loss.(x); label = "quadratic loss")
    lines!(ax, bp, loss.(bp); linestyle = :dash, label = "linearised (5 segments here)")
    scatter!(ax, bp, loss.(bp); color = :tomato)
    axislegend(ax; position = :ct)
    fig
end

# ## Generic constraints
#
# ### Network constraints
#
# AEMO needs to dispatch the units while preserving the integrity of the transmission network. It does so by
# introducing **generic constraints** that describe the network limits. A **generic constraint** (also called constraint equations) is a linear inequality over unit
# outputs, FCAS enablements and interconnector flows,
#
# ```math
# \sum_{u} a_{g,u}\, p_u + \sum_{u,k} a^{k}_{g,u}\, f_{u,k} + \sum_i a_{g,i}\, x_i \;\; \{\le, =, \ge\} \;\; \mathrm{RHS}_g
# ```
#
# A thermal limit on a line, the stability limit of a group of generators or a limit on the sum of
# flows into a region are all of this form. Which constraints apply in an interval is decided by
# AEMO (they are *invoked*), and their right-hand sides are re-evaluated for every interval. The
# dual value of a binding generic constraint is its **marginal value**: it measures how much
# the network limit costs and is what separates regional prices.
#
# ### Elastic constraints
#
# NEMDE must always return a dispatch. Every generic constraint therefore carries a violation
# variable ``v_g \ge 0`` that relaxes it, paid at the constraint's *violation penalty factor*
# ``w_g`` times the Market Price Cap (MPC):
#
# ```math
# \sum_u a_{g,u}\, p_u + \dots - v_g \le \mathrm{RHS}_g, \qquad
# \text{penalty} = w_g \, \mathrm{MPC}\, \Delta \, v_g
# ```
#
# The factors define a priority order of what NEMDE gives up first when constraints conflict
# (AEMO, *Schedule of Constraint Violation Penalty Factors*). The same device is applied to other
# families of constraints, for example:
#
# | Constraint family | Factor ``w`` (times the MPC) |
# | --- | --- |
# | Unit ramp rate | 1155 |
# | Interconnector capacity limit | 1150 |
# | UIGF (semi-scheduled availability) | 385 |
# | FCAS joint ramping | 155 |
# | Regional power balance (load shedding, excess generation) | 150 |
# | FCAS enablement min / max (trapezium) | 70 |
# | Secure network limit, stability | 35 |
# | Secure network limit, thermal | 30 |
#
# so that in an infeasible interval the cheapest violation is taken first, demand is left unserved
# (``150 \times \mathrm{MPC}``) before an interconnector limit is broken (``1150 \times
# \mathrm{MPC}``).
#
# ### FCAS requirements
#
# The ten FCAS services (raise and lower, for 1 second, 6 seconds, 60 seconds, 5 minutes, and
# regulation) are procured in the same optimisation. Each service has a requirement per region
# (or for the NEM), published by AEMO as a **generic constraint** whose left-hand side is the
# sum of the enabled FCAS across units:
#
# ```math
# \sum_{u \in r} f_{u,k} \;\ge\; \mathrm{REQ}_{r,k}
# ```
#
# The dual of this requirement is the FCAS price. Some requirements involve several regions (a
# service can be provided from outside the region that needs it) and, for regulation, count only
# part of other services toward the requirement.
#
# ## FCAS constraints on units: the trapezium
#
# A unit cannot sell more FCAS than it can actually deliver, and FCAS depends on where the unit
# operates in *energy*: a generator at its maximum has no room left to raise, and a generator
# below its minimum stable level cannot lower. Each FCAS offer therefore comes with a
# **trapezium** in the energy and FCAS plane with five parameters: ``E^{\min}``,
# the low break point ``L``, the high break point ``H``, ``E^{\max}`` and the maximum
# availability ``F^{\max}`` (AEMO, *FCAS Model in NEMDE* §2-3). A unit may be dispatched at any
# ``(p_u, f_u)`` inside it:
#
# ```math
# 0 \le f_u \le F^{\max}, \qquad
# p_u + \underbrace{\frac{E^{\max} - H}{F^{\max}}}_{\text{upper slope}}\, f_u \le E^{\max}, \qquad
# p_u - \underbrace{\frac{L - E^{\min}}{F^{\max}}}_{\text{lower slope}}\, f_u \ge E^{\min}
# ```
#
# These two *joint* constraints couple energy and FCAS: energy and FCAS compete for the same MW,
# which is why NEMDE co-optimises them. FCAS also raises the price of energy when it is
# provided by a unit that would otherwise be generating more, by exactly the opportunity cost
# of the energy given up.

let
    E = (150.0, 200.0, 350.0, 450.0, 60.0)
    fig = Figure(size = (900, 330))
    ax = Axis(fig[1, 1]; xlabel = "Energy dispatch (MW)", ylabel = "RAISE6SEC (MW)", title = "FCAS trapezium")
    poly!(
        ax, Point2f[(E[1], 0), (E[2], E[5]), (E[3], E[5]), (E[4], 0)];
        color = (Makie.wong_colors()[1], 0.35), strokecolor = Makie.wong_colors()[1], strokewidth = 2,
    )
    labels = (
        (E[1], 0, "Emin"), (E[2], E[5], "low breakpoint"), (E[3], E[5], "high breakpoint"), (E[4], 0, "Emax"),
    )
    for (x, y, label) in labels
        scatter!(ax, x, y; color = :tomato, markersize = 10)
        text!(ax, x, y + (y == 0 ? 3 : 4); text = label, align = (:center, :bottom), fontsize = 11)
    end
    text!(ax, E[3] - 30, E[5] / 2; text = "max availability = $(Int(E[5])) MW", align = (:right, :center), fontsize = 11)
    ylims!(ax, -4, 80)
    fig
end

# ## UIGF: forecasts for semi-scheduled units
#
# Wind and solar farms are *semi-scheduled*: their output depends on the weather, and AEMO
# forecasts the maximum they could produce, the **unconstrained intermittent generation forecast**
# (UIGF), for every interval. The forecast has three effects on the dispatch:
#
# 1. **Availability.** The usable capacity of a semi-scheduled unit is the smaller of its offered
#    availability and the forecast, so the ceiling of the energy envelope is
#    ``\text{AVAIL}_u = \min(\text{MAXAVAIL}_u, \text{UIGF}_u)``. Offer bands above the
#    forecast cannot be dispatched, however cheap they are.
# 2. **The FCAS trapezium.** NEMDE uses the more restrictive of the bid's ``E^{\max}`` and the UIGF
#    as the effective enablement maximum and moves the high break point inwards so that the slope
#    of the upper edge is preserved (AEMO, *FCAS Model in NEMDE* §4.3), for regulation and
#    contingency services alike.
# 3. **The ramp envelope.** The ramp constraints apply as usual; the forecast simply lowers the
#    ceiling they are clipped at. The forecast cap is itself a soft constraint (penalty factor 385
#    in the table above), above the network constraints, so the forecast is respected before a
#    network limit is relaxed.

let
    fig = Figure(size = (900, 330))
    ax = Axis(fig[1, 1]; xlabel = "Cumulative offered MW", ylabel = "Offer price (\$/MWh)", title = "Offer bands against the forecast")
    poly!(ax, Rect2f(0, 0, 150, 3); color = (Makie.wong_colors()[3], 0.8), strokecolor = Makie.wong_colors()[3], strokewidth = 1)
    poly!(ax, Rect2f(150, 0, 50, 3); color = (Makie.wong_colors()[3], 0.15), strokecolor = Makie.wong_colors()[3], strokewidth = 1, linestyle = :dash)
    vlines!(ax, 150; color = :tomato, label = "UIGF = 150 MW")
    text!(ax, 155, 12; text = "offered but not dispatchable", align = (:left, :bottom), fontsize = 11)
    axislegend(ax; position = :rt)
    ylims!(ax, 0, 40)

    ax2 = Axis(fig[1, 2]; xlabel = "Energy dispatch (MW)", ylabel = "RAISE6SEC (MW)", title = "Trapezium scaled by the forecast")
    emin, low, high, emax, fmax = 40.0, 70.0, 160.0, 200.0, 20.0
    uigf = 150.0
    new_high = uigf - (emax - high)
    poly!(ax2, Point2f[(emin, 0), (low, fmax), (high, fmax), (emax, 0)]; color = (:gray, 0.15), strokecolor = :gray, strokewidth = 2)
    poly!(
        ax2, Point2f[(emin, 0), (low, fmax), (new_high, fmax), (uigf, 0)];
        color = (Makie.wong_colors()[3], 0.35), strokecolor = Makie.wong_colors()[3], strokewidth = 2,
    )
    ylims!(ax2, -2, 28)
    Legend(
        fig[2, 1:2],
        [PolyElement(color = (:gray, 0.4)), PolyElement(color = Makie.wong_colors()[3])],
        ["bid trapezium", "effective trapezium (Emax = UIGF)"]; orientation = :horizontal, tellheight = true,
    )
    fig
end

# ## The whole problem
#
# Putting the pieces together, one dispatch interval is
#
# ```math
# \begin{aligned}
# \min \;& \Delta\Big(\sum_{u,b} \pi_{u,b} q_{u,b} + \sum_{u,k,b} \pi^k_{u,b} q^k_{u,b}\Big) + \sum_g w_g\,\mathrm{MPC}\,\Delta\, v_g + \dots \\
# \text{s.t. } & p_u = \textstyle\sum_b q_{u,b}, \quad 0 \le q_{u,b} \le Q_{u,b} && \text{bids} \\
# & p_u \le \min(\text{MAXAVAIL}_u, \text{UIGF}_u), \quad -R^{\downarrow}_u \Delta \le p_u - p^0_u \le R^{\uparrow}_u \Delta && \text{unit envelope} \\
# & \text{fast start profile of unit } u && \text{fast start} \\
# & -\bar X^{\leftarrow}_i \le x_i \le \bar X^{\rightarrow}_i, \quad L_i = L_i(x_i, D) && \text{interconnectors} \\
# & \textstyle\sum_{u \in r} p_u - \sum_i \pm x_i - \sum_i (\text{share}) L_i = D_r \quad (\lambda_r) && \text{regional balance} \\
# & \textstyle\sum_{u \in r} f_{u,k} \ge \mathrm{REQ}_{r,k} \quad (\lambda_{r,k}) && \text{FCAS requirements} \\
# & (p_u, f_{u,k}) \in \text{trapezium}_{u,k} && \text{FCAS capability} \\
# & \textstyle\sum a_{g,\cdot}\,(\cdot) - v_g \le \mathrm{RHS}_g && \text{generic constraints}
# \end{aligned}
# ```
#
# The prices ``\lambda`` are the duals of the balance and requirement constraints. The next page
# builds this model for a market small enough to read in full.
#
# ## [References](@id nemde-model-references)
#
# - AEMO, [*FCAS Model in NEMDE*](https://nempy.readthedocs.io/en/latest/_downloads/e3c8a21d3084db332a30bd0d564e93c3/FCAS%20Model%20in%20NEMDE.pdf):
#   the trapezium (§2-3), scaling (§4) and joint constraints (§6).
# - AEMO, *Fast Start Inflexibility Profile*: ``T_1`` to ``T_4`` and the dispatch modes.
# - AEMO, *Marginal Loss Factors* and *Loss Factor Methodology*: the inter-regional loss equations,
#   ``\text{Losses} = \int (\text{loss factor} - 1)\, d\text{Flow}``.
# - AEMO, *Schedule of Constraint Violation Penalty Factors*: the penalty of each constraint family.
# - AEMO, *Constraint Formulation Guidelines*: the form of generic constraints.
# - AEMO, [*NEMDE queue and dispatch process*](https://www.aemo.com.au/energy-systems/electricity/national-electricity-market-nem/system-operations/dispatch).
