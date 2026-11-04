using CairoMakie #hide

# # [FCAS capability and co-optimisation](@id nemde-fcas)
#
# Supply and demand must balance second by second, and the five-minute energy market cannot
# do that by itself. AEMO therefore buys reserves, called **frequency control ancillary
# services (FCAS)**: capacity that is held ready to raise or lower output when frequency
# moves. The same generators, batteries and loads provide both energy and FCAS, and a MW
# held in reserve is a MW not sold as energy. NEMDE therefore clears the two together.
#
# ## The ten services
#
# The NEM runs at 50 Hz. A **raise** service increases net injection when frequency falls. A
# **lower** service decreases it when frequency rises. A generator provides raise by
# producing more, a load by consuming less, and a battery by either. The name describes the
# effect on the system, not what the provider does.
#
# There are two families.
#
# - **Regulation** corrects the small, continuous imbalances of normal operation. Enabled
#   units follow setpoints that AEMO's automatic generation control (AGC) sends every few
#   seconds.
# - **Contingency** services are held for a sudden event, such as the loss of a large
#   generator. They are delivered only if frequency leaves its normal band, and are
#   distinguished by how fast they must respond.
#
# | Family | Response time | Raise market | Lower market |
# | --- | --- | --- | --- |
# | Regulation | Continuous, under AGC | `RAISEREG` | `LOWERREG` |
# | Very fast contingency | 1 second | `RAISE1SEC` | `LOWER1SEC` |
# | Fast contingency | 6 seconds | `RAISE6SEC` | `LOWER6SEC` |
# | Slow contingency | 60 seconds | `RAISE60SEC` | `LOWER60SEC` |
# | Delayed contingency | 5 minutes | `RAISE5MIN` | `LOWER5MIN` |
#
# The ten services are separate markets with separate offers and separate prices. A unit can
# be enabled for several at once. AEMO describes the services in its
# [Guide to Frequency Control Ancillary Services, v4.0, §§2-3, pp. 5-8](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/ancillary_services/guide-to-frequency-control-ancillary-services.pdf)
# and the delivery obligations in its
# [Market Ancillary Service Specification](https://www.aemo.com.au/energy-systems/electricity/national-electricity-market-nem/system-operations/ancillary-services/market-ancillary-service-specification-and-fcas-verification-tool).
#
# ### Enablement is capacity held in reserve
#
# NEMDE decides how many MW of each service to **enable** on each unit. Write ``f_{u,j}`` for
# the MW of service ``j`` enabled on unit ``u``. An enabled MW is a commitment to respond if
# called. It is paid for whether or not a frequency event occurs, and it adds nothing to the
# regional energy balance. The unit's energy target is a separate decision.
#
# ## How much is required
#
# ### Requirements for the whole market and for a region
#
# In the simplest case a service must be enabled to at least a required amount across a set
# of regions:
#
# ```math
# \sum_{u\in\mathcal U}f_{u,j}\ge b_g.
# ```
#
# ``\mathcal U`` is every eligible unit in the regions the requirement ``g`` covers. FCAS can
# usually be supplied from anywhere on the interconnected system, so most requirements cover
# all regions. When a region could be cut off from the rest, for instance Tasmania, which is
# connected by a single cable, AEMO adds a **local** requirement that only units in that
# region can meet. Both apply at once.
#
# AEMO writes every FCAS requirement as a generic constraint, the same linear form used for
# network limits:
#
# ```math
# \sum_{u,j}w_{g,u,j}\,f_{u,j}+\sum_uw_{g,u}\,p_u+\sum_iw_{g,i}\,x_i
# \;\{\le,\,=,\,\ge\}\;b_g.
# ```
#
# The coefficients ``w`` select which services, units and interconnectors count. Energy and
# flow terms appear because some requirements depend on dispatch. The reserve needed to
# cover the loss of an interconnector, for example, grows with its flow. A requirement can
# therefore not be read from its right-hand side alone. Its sense and its full left-hand
# side are part of its meaning. See AEMO's
# [Constraint Formulation Guidelines, v13, §5, pp. 16-20](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/constraint-formulation-guidelines.pdf)
# and [Violations, tie-breaking and prices](@ref nemde-prices).
#
# ### An example with a local requirement
#
# Three units each have 60 MW of capability in one contingency service. A market-wide
# requirement needs 100 MW. A, B and C offer at \$2, \$5 and \$9 per MW per hour, and C is
# the only unit in a region that could be cut off.
#
# With the market-wide requirement alone, the cheapest allocation is 60 MW from A and 40 MW
# from B. Add a local requirement of 30 MW in C's region. C must now supply 30 MW, and the
# cheapest allocation becomes 60 MW from A, 10 MW from B and 30 MW from C. C's 30 MW counts
# towards both requirements, so 100 MW is enabled in total, not 130 MW.

let #hide
    offered = [60.0, 60.0, 60.0] #hide
    shared = [60.0, 40.0, 0.0] #hide
    local_and_shared = [60.0, 10.0, 30.0] #hide
    labels = ["A: outside the local region", "B: outside the local region", "C: in the local region"] #hide
    colors = Makie.wong_colors()[1:3] #hide
    fig = Figure(size = (1000, 420)) #hide
    for (col, enabled, title) in ( #hide
            (1, shared, "Market-wide requirement only: 100 MW"), #hide
            (2, local_and_shared, "Market-wide 100 MW and local 30 MW"), #hide
        ) #hide
        ax = Axis( #hide
            fig[1, col]; title, ylabel = "Enabled (MW)", #hide
            xticks = (1:3, ["A (\$2)", "B (\$5)", "C (\$9)"]), #hide
            xlabel = "Unit (offer price in \$ per MW per hour)", #hide
        ) #hide
        barplot!(ax, 1:3, offered; color = (:gray, 0.18), strokecolor = :gray, strokewidth = 1) #hide
        barplot!(ax, 1:3, enabled; color = colors, width = 0.65) #hide
        for j in 1:3 #hide
            text!(ax, j, enabled[j] + 2; text = "$(Int(enabled[j])) MW", align = (:center, :bottom)) #hide
        end #hide
        ylims!(ax, 0, 72) #hide
    end #hide
    Legend( #hide
        fig[2, 1:2], [PolyElement(color = c) for c in colors], labels; #hide
        orientation = :horizontal, tellwidth = false, #hide
    ) #hide
    Label(fig[3, 1:2], "Grey outlines: capability offered. Coloured bars: capability enabled."; fontsize = 13) #hide
    fig #hide
end #hide

# *Constructed example for one service, with energy dispatch held fixed.*
#
# In a real interval NEMDE can also move a unit's energy target to free up FCAS capability,
# or the reverse. A merit order of FCAS offers alone therefore does not reproduce the
# enablement. The offers, the requirements and each unit's capability are solved together
# ([FCAS Model in NEMDE, §1.1, p. 4](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf)).
#
# ## What a unit offers
#
# ### Price bands
#
# For each service, a unit submits ten price bands, as for energy: prices fixed for the
# trading day and quantities per interval. Write ``Q_{u,j,b}`` for the MW offered in band
# ``b``, ``c_{u,j,b}`` for its price and ``q_{u,j,b}`` for the MW cleared:
#
# ```math
# 0\le q_{u,j,b}\le Q_{u,j,b},\qquad
# f_{u,j}=\sum_bq_{u,j,b},\qquad
# C_F=h\sum_{u,j,b}c_{u,j,b}\,q_{u,j,b}.
# ```
#
# The cleared bands add up to the enablement, and ``C_F`` is the FCAS part of the objective.
# An FCAS price is a price per MW enabled, per hour. AEMO's tables label it \$/MWh; the MWh
# is a MW of capability held for an hour, not energy delivered. FCAS prices are not adjusted
# by loss factors.
#
# ### [The trapezium](@id fcas-trapezium)
#
# How much FCAS a unit can provide depends on where it is operating. A generator at full
# output has no room to raise. A generator near its minimum has no room to lower. Each FCAS
# offer therefore includes an envelope, the **FCAS trapezium**, that gives the maximum
# enablement as a function of the unit's energy target. Five numbers define it.
#
# | Symbol | Offer field | Meaning |
# | --- | --- | --- |
# | ``E^{\min}`` | `ENABLEMENTMIN` | Energy level below which no FCAS can be enabled |
# | ``B^{\mathrm{lo}}`` | `LOWBREAKPOINT` | Energy level at which the full amount becomes available |
# | ``B^{\mathrm{hi}}`` | `HIGHBREAKPOINT` | Energy level above which the amount starts to fall |
# | ``E^{\max}`` | `ENABLEMENTMAX` | Energy level above which no FCAS can be enabled |
# | ``F`` | `MAXAVAIL` | The full amount, in MW of FCAS |
#
# The offer satisfies ``E^{\min}\le B^{\mathrm{lo}}\le B^{\mathrm{hi}}\le E^{\max}``. The two
# sloping sides are described by how many MW of energy range each MW of FCAS uses up:
#
# ```math
# \alpha^{\mathrm{lo}}=\frac{B^{\mathrm{lo}}-E^{\min}}{F},\qquad
# \alpha^{\mathrm{hi}}=\frac{E^{\max}-B^{\mathrm{hi}}}{F}.
# ```
#
# Write ``\tilde p`` for the unit's energy target on the axis of its offer; the next section
# says what that axis is for each kind of unit. The trapezium is then three linear
# inequalities:
#
# ```math
# 0\le f\le F,\qquad
# \tilde p-\alpha^{\mathrm{lo}}f\ge E^{\min},\qquad
# \tilde p+\alpha^{\mathrm{hi}}f\le E^{\max}.
# ```
#
# The first caps the enablement at the full amount. The second and third are the lower and
# upper sloping sides. A coefficient of zero gives a vertical side. See
# [FCAS Model in NEMDE, v3.0, §§2-3, pp. 6-13](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).

function fcas_review_envelope(e, emin, emax, fmax, lower, upper) #hide
    left = iszero(lower) ? (e >= emin ? Inf : 0.0) : (e - emin) / lower #hide
    right = iszero(upper) ? (e <= emax ? Inf : 0.0) : (emax - e) / upper #hide
    return max(0.0, min(fmax, left, right)) #hide
end #hide
#hide
let #hide
    xs = range(0, 320; length = 641) #hide
    ys = fcas_review_envelope.(xs, 40.0, 280.0, 40.0, 1.5, 2.0) #hide
    fig = Figure(size = (850, 360)) #hide
    ax = Axis(fig[1, 1]; xlabel = "Energy target (MW)", ylabel = "Maximum enablement (MW)", title = "Illustrative FCAS trapezium") #hide
    band!(ax, xs, zero.(xs), ys; color = (:steelblue, 0.18)) #hide
    lines!(ax, xs, ys; color = :steelblue, linewidth = 3) #hide
    scatter!(ax, [40, 100, 200, 280], [0, 40, 40, 0]; color = :steelblue, markersize = 9) #hide
    ax.xticks = ([40, 100, 200, 280], ["Emin = 40", "Blo = 100", "Bhi = 200", "Emax = 280"]) #hide
    ax.yticks = ([0, 20, 40], ["0", "20", "F = 40"]) #hide
    for (e, f) in ((70, 20), (150, 40), (240, 20)) #hide
        vlines!(ax, [e]; color = (:black, 0.25), linestyle = :dash) #hide
        scatter!(ax, [e], [f]; color = :darkorange, markersize = 11) #hide
    end #hide
    ylims!(ax, 0, 48) #hide
    fig #hide
end #hide

# *Constructed example. The unit can be enabled for up to 20 MW at an energy target of 70 MW,
# 40 MW at 150 MW and 20 MW at 240 MW.*
#
# ### [The energy axis of each kind of unit](@id fcas-cases-participants)
#
# The horizontal axis of a trapezium is the quantity the unit offers in the energy market.
#
# | Unit | Energy axis ``\tilde p`` | To provide raise | To provide lower |
# | --- | --- | --- | --- |
# | Generator | Generation, positive | Generate more | Generate less |
# | Scheduled load | Consumption, positive | Consume less | Consume more |
# | Battery, contingency services | Net injection: positive generating, negative charging | Inject more | Inject less |
# | Battery, regulation services | One offer on its generation, one on its consumption | Either | Either |
#
# A load's axis runs the opposite way to its effect on the system, which reverses the role
# of raise and lower in some of the constraints below
# ([FCAS Model in NEMDE, §§2.1-2.4, pp. 7-10](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf)).
#
# ## [Adjusting the offer to the interval](@id fcas-cases-scaling)
#
# The trapezium is offered as part of a bid. Before each solve AEMO shrinks it to what the unit
# can do in this interval, and then checks whether the unit can be enabled at all. Neither
# step involves the optimisation.
#
# ### Scaling
#
# Three inputs can make the trapezium smaller.
#
# - **AGC limits.** A unit reports the range over which AGC can control it. A regulation
#   trapezium is cut to that range.
# - **AGC ramp rate.** A unit can deliver in regulation no more than it can ramp in five
#   minutes. A regulation trapezium is cut to that height.
# - **Wind and solar forecast.** A semi-scheduled unit cannot operate above its forecast
#   (UIGF). Every one of its trapeziums is cut at that level.
#
# Write a prime for the adjusted values, ``E^{\mathrm{AGC}}`` for the AGC limits and
# ``R^{\mathrm{AGC}}`` for the AGC ramp rate in the direction of the service:
#
# ```math
# \begin{aligned}
# E^{\min\prime}&=\max\big(E^{\min},\,E^{\mathrm{AGC}}_{\min}\big),\\
# E^{\max\prime}&=\min\big(E^{\max},\,E^{\mathrm{AGC}}_{\max},\,\mathrm{UIGF}\big),\\
# F'&=\min\big(F,\,R^{\mathrm{AGC}}\,h\big),\\
# B^{\mathrm{lo}\prime}&=E^{\min\prime}+\alpha^{\mathrm{lo}}F',\qquad
# B^{\mathrm{hi}\prime}=E^{\max\prime}-\alpha^{\mathrm{hi}}F'.
# \end{aligned}
# ```
#
# A term is left out where it does not apply: the AGC terms for contingency services, and
# the UIGF for scheduled units. An AGC limit or rate that is zero or missing is ignored. A
# UIGF of zero is a real limit. The slopes ``\alpha`` are kept, so the breakpoints move with
# the limits. From here on, every trapezium parameter means its adjusted value. See
# [FCAS Model in NEMDE, §4, pp. 14-17](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).

let #hide
    xs = range(0, 320; length = 641) #hide
    bid = fcas_review_envelope.(xs, 40.0, 280.0, 40.0, 1.5, 2.0) #hide
    cases = [ #hide
        ("AGC limits: 70 to 250 MW", 70.0, 250.0, 40.0), #hide
        ("AGC ramp: 25 MW in five minutes", 40.0, 280.0, 25.0), #hide
        ("Forecast (UIGF): 230 MW", 40.0, 230.0, 40.0), #hide
    ] #hide
    fig = Figure(size = (1100, 350)) #hide
    for (i, (title, emin, emax, fmax)) in enumerate(cases) #hide
        ax = Axis(fig[1, i]; title, titlesize = 14, xlabel = "Energy target (MW)", ylabel = i == 1 ? "Maximum enablement (MW)" : "") #hide
        effective = fcas_review_envelope.(xs, emin, emax, fmax, 1.5, 2.0) #hide
        lines!(ax, xs, bid; color = :gray, linestyle = :dash, linewidth = 2, label = "Offered") #hide
        band!(ax, xs, zero.(xs), effective; color = (:steelblue, 0.18)) #hide
        lines!(ax, xs, effective; color = :steelblue, linewidth = 3, label = "Adjusted") #hide
        ylims!(ax, 0, 48) #hide
        i == 1 && axislegend(ax; position = :rt, labelsize = 12) #hide
    end #hide
    fig #hide
end #hide

# *Each panel applies one input to the trapezium of the previous figure. They can also apply
# together. The sloping sides keep their slopes.*
#
# The standard input workflow attaches telemetered scaling inputs to available generators,
# batteries and interruptible loads. Missing AGC ramp inputs leave the corresponding joint
# ramping rows inactive. See the FCAS interval inspection guide, which is not yet published, for the
# construction and effective-offer preprocessing sequence.
#
# ### [Can the unit be enabled at all?](@id fcas-cases-preconditions)
#
# After scaling, AEMO checks each offer. An offer that fails the requirements is excluded: its
# enablement is fixed at zero for the interval. Passing does not mean the unit will be
# enabled, only that it may be.
#
# | Test | Generator or scheduled load | Battery |
# | --- | --- | --- |
# | Something is offered | ``F>0`` and at least one band has a positive quantity | The same |
# | The range is usable | ``E^{\max}\ge0`` | For regulation offered on consumption, ``E^{\min}\le0``. No sign test for contingency |
# | Energy availability reaches the range | Availability, or the UIGF if lower, is at least ``E^{\min}`` | Generation availability is at least ``E^{\min}``, and the negative of consumption availability is at most ``E^{\max}`` |
# | The unit starts inside the range | ``E^{\min}\le\max(p^0,0)\le E^{\max}`` | ``E^{\min}\le p^0\le E^{\max}``, with ``p^0`` negative when charging. With regulation offered on both sides, from ``E^{\min}`` of the consumption offer to ``E^{\max}`` of the generation offer |
# | Regulation only: the unit is on AGC | Required | Required |
#
# The fourth test has a specific name. A unit that begins the interval outside the range of a
# trapezium is **stranded**: it cannot be enabled for that service until it has moved back
# inside. The starting point ``p^0`` is the metered output, as for ramp rates. See
# [FCAS Model in NEMDE, §5, pp. 18-19](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
#
# ## [Energy and FCAS together](@id fcas-cooptimisation)
#
# One trapezium limits one service. A unit enabled for several services, while also changing
# its energy target, is subject to further constraints that tie them together. Write
# ``f^{\mathrm{RR}}`` and ``f^{\mathrm{LR}}`` for the unit's raise and lower regulation
# enablement.
#
# ### [Contingency and regulation share headroom](@id fcas-cases-joint)
#
# A unit that is providing raise regulation may already have moved up by that amount when a
# contingency occurs. The headroom for a contingency raise service is therefore reduced by
# the raise regulation enabled. For each contingency service ``j`` on a generator or
# battery:
#
# ```math
# \tilde p+\alpha_j^{\mathrm{hi}}f_j+f^{\mathrm{RR}}\le E^{\max}_j,\qquad
# \tilde p-\alpha_j^{\mathrm{lo}}f_j-f^{\mathrm{LR}}\ge E^{\min}_j.
# ```
#
# These are the two sloping sides of the trapezium, moved inward by the regulation enabled.
# For a scheduled load, whose axis is consumption, the regulation terms swap:
# ``f^{\mathrm{LR}}`` enters the upper constraint and ``f^{\mathrm{RR}}`` the lower.
#
# Each contingency service has its own pair of constraints. The four raise contingency
# services do not compete with one another for headroom, because they describe the same
# response at different moments after an event. See
# [FCAS Model in NEMDE, §6.2, pp. 22-26](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).

let #hide
    xs = range(0, 320; length = 641) #hide
    fig = Figure(size = (950, 360)) #hide
    for (i, title, emin, emax) in ( #hide
            (1, "With 20 MW of raise regulation", 40.0, 260.0), #hide
            (2, "With 20 MW of lower regulation", 60.0, 280.0), #hide
        ) #hide
        ax = Axis(fig[1, i]; title, xlabel = "Generation target (MW)", ylabel = i == 1 ? "Maximum contingency enablement (MW)" : "") #hide
        original = fcas_review_envelope.(xs, 40.0, 280.0, 40.0, 1.5, 2.0) #hide
        joint = fcas_review_envelope.(xs, emin, emax, 40.0, 1.5, 2.0) #hide
        lines!(ax, xs, original; color = :gray, linestyle = :dash, linewidth = 2, label = "No regulation enabled") #hide
        band!(ax, xs, zero.(xs), joint; color = (:steelblue, 0.18)) #hide
        lines!(ax, xs, joint; color = :steelblue, linewidth = 3, label = "Regulation enabled") #hide
        ylims!(ax, 0, 48) #hide
        i == 1 && axislegend(ax; position = :rt, labelsize = 12) #hide
    end #hide
    fig #hide
end #hide

# *For the generator of the earlier figures, 20 MW of raise regulation moves the upper side
# of a contingency trapezium 20 MW to the left. Lower regulation moves the lower side 20 MW
# to the right.*
#
# ### Regulation and the energy ramp share the ramp rate
#
# Each regulation service keeps its own trapezium:
# ``\tilde p+\alpha^{\mathrm{hi}}f\le E^{\max}`` and
# ``\tilde p-\alpha^{\mathrm{lo}}f\ge E^{\min}``, with ``0\le f\le F``
# ([FCAS Model in NEMDE, §6.3, pp. 26-27](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf)).
#
# In addition, regulation is delivered by ramping, and so is the change in energy target.
# The two together cannot exceed what the unit can ramp in the interval, measured from its
# metered starting point ``p^0``. For a generator or battery:
#
# ```math
# \tilde p+f^{\mathrm{RR}}\le p^0+R^{\mathrm{AGC}\uparrow}h,\qquad
# \tilde p-f^{\mathrm{LR}}\ge p^0-R^{\mathrm{AGC}\downarrow}h.
# ```
#
# For a scheduled load the regulation terms swap again:
# ``\tilde p+f^{\mathrm{LR}}\le p^0+R^{\mathrm{AGC}\uparrow}h`` and
# ``\tilde p-f^{\mathrm{RR}}\ge p^0-R^{\mathrm{AGC}\downarrow}h``. See
# [FCAS Model in NEMDE, §6.1, pp. 21-22](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
#
# A generator metered at 150 MW that can ramp up 30 MW in five minutes, and is sent to
# 170 MW, has 10 MW left for raise regulation, whatever its trapezium allows.
#
# Units with a fast-start profile that begin the interval before reaching minimum load are
# exempt from these two constraints; see [Fast-start dispatch](@ref nemde-fast-start).
#
# !!! note "Deviation in AustralianElectricityMarketsSimulations"
#     **AEMO:** exempts fast-start units in modes 0, 1 and 2 from joint ramping. **This
#     package:** has no fast-start modes, so the joint ramping constraints apply to those
#     units as to any other.
#
# ### Batteries offer regulation on each side
#
# A battery makes one offer per contingency service, on its net injection. For regulation it
# can make two: one on its generation and one on its consumption, each with its own prices,
# bands and trapezium
# ([FCAS Model in NEMDE, §2.4, pp. 8-10](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf)).
# The battery's regulation enablement is the sum of the two sides:
#
# ```math
# f^{\mathrm{RR}}=f^{\mathrm{RR}}_{\mathrm{gen}}+f^{\mathrm{RR}}_{\mathrm{load}},\qquad
# f^{\mathrm{LR}}=f^{\mathrm{LR}}_{\mathrm{gen}}+f^{\mathrm{LR}}_{\mathrm{load}}.
# ```
#
# These totals are what count towards requirements and what enter the two joint constraints
# above. Each side was scaled to the battery's full AGC ramp rate, so a further constraint
# stops the two sides from using that rate twice:
#
# ```math
# f^{\mathrm{RR}}_{\mathrm{gen}}+f^{\mathrm{RR}}_{\mathrm{load}}\le R^{\mathrm{AGC}\uparrow}h,\qquad
# f^{\mathrm{LR}}_{\mathrm{gen}}+f^{\mathrm{LR}}_{\mathrm{load}}\le R^{\mathrm{AGC}\downarrow}h.
# ```
#
# See [FCAS Model in NEMDE, §6.4, p. 27](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
#
# ## [What is published as availability](@id fcas-cases-availability)
#
# After the solve, AEMO publishes for each unit and service an **actual availability**: the
# most the unit could have been enabled for, at the energy target it was given and with its
# other services as enabled. For a contingency service on a generator it is
#
# ```math
# \max\left(0,\;\min\left\{F_j,\;
# \frac{\tilde p-E^{\min}_j-f^{\mathrm{LR}}}{\alpha_j^{\mathrm{lo}}},\;
# \frac{E^{\max}_j-\tilde p-f^{\mathrm{RR}}}{\alpha_j^{\mathrm{hi}}}\right\}\right).
# ```
#
# This is the joint capacity constraint solved for the enablement. A side with a zero slope
# is left out of the minimum. Four numbers are easily confused: the amount **offered**, the
# amount after **scaling**, the **actual availability** at the dispatched point, and the
# amount **enabled**. Each is normally no greater than the one before it. See
# [FCAS Model in NEMDE, §7, pp. 29-33](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).

let #hide
    fig = Figure(size = (850, 300)) #hide
    ax = Axis(fig[1, 1]; ylabel = "MW", title = "Four stages of one illustrative FCAS offer", xticks = (1:4, ["Offered", "After scaling", "Actual availability", "Enabled"])) #hide
    barplot!(ax, 1:4, [40, 30, 20, 12]; color = Makie.wong_colors()[1:4]) #hide
    for (i, mw) in enumerate([40, 30, 20, 12]) #hide
        text!(ax, i, mw + 1; text = "$mw MW", align = (:center, :bottom)) #hide
    end #hide
    ylims!(ax, 0, 47) #hide
    fig #hide
end #hide

# *Constructed quantities. The requirement was met without using all of the unit's actual
# availability.*
#
# !!! note "Deviation in AustralianElectricityMarketsSimulations"
#     **AEMO:** publishes actual availability for every unit and service. **AustralianElectricityMarkets.jl:**
#     does not compute it. The published values can be read from the data for comparison.
#
# ## [FCAS prices](@id fcas-pricing)
#
# The price of a service in a region is the cost of requiring one more MW of it. In
# the optimisation that is the sum of the marginal values of every requirement that covers
# the region for that service.
#
# In the three-unit example, one more MW of the market-wide requirement comes from B at \$5.
# One more MW of the local requirement comes from C at \$9 and displaces a MW of B, a net
# cost of \$4. Units outside the local region are paid \$5 per MW per hour. C, which
# satisfies both requirements, is paid \$5 + \$4 = \$9.
#
# Two effects make real prices less direct than this.
#
# - **Lost energy revenue.** If a unit must be moved off its preferred energy target to make
#   room for FCAS, the cost of doing so is part of the marginal cost of the service. An FCAS
#   price can therefore exceed every FCAS offer.
# - **Shortfall.** If a requirement cannot be met, its marginal value is its violation
#   penalty and not a market price. The published price is then set by a further pricing
#   step; see [Violations, tie-breaking and prices](@ref nemde-prices).
#
# Only requirements set prices. The marginal value of a unit's trapezium or ramping
# constraint is not a service price.
#
# ## A worked example
#
# A generator has the contingency raise trapezium of the figures: ``E^{\min}=40``,
# ``B^{\mathrm{lo}}=100``, ``B^{\mathrm{hi}}=200``, ``E^{\max}=280`` and ``F=40`` MW, so
# ``\alpha^{\mathrm{hi}}=(280-200)/40=2``. It also offers 30 MW of raise regulation. It is
# metered at 230 MW and its AGC ramp-up rate is 180 MW per hour, or 15 MW in five minutes.
#
# | Step | Calculation | Result |
# | --- | --- | --- |
# | Scale raise regulation to the ramp rate | ``\min(30,\,15)`` | 15 MW can be offered |
# | Energy target chosen by the optimisation | | 240 MW |
# | Joint ramping | ``240+f^{\mathrm{RR}}\le230+15`` | At most 5 MW of raise regulation |
# | Contingency raise, with 5 MW of regulation enabled | ``(280-240-5)/2`` | At most 17.5 MW |
# | Contingency raise, with no regulation enabled | ``(280-240)/2`` | At most 20 MW |
#
# Moving the energy target up by 10 MW used two thirds of the ramp rate, and each MW of
# regulation costs half a MW of contingency raise. Whether the optimisation accepts those
# trades depends on the prices of energy and of each service.
#
# To read a real interval's offers, requirements and prices from the cache, see the FCAS
# interval inspection guide, which is not yet published.
#
# ## [References](@id fcas-references)
#
# - AEMO, [FCAS Model in NEMDE, v3.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf): offers, scaling, eligibility, joint constraints and availability.
# - AEMO, [Guide to Frequency Control Ancillary Services, v4.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/ancillary_services/guide-to-frequency-control-ancillary-services.pdf): the services and their purpose.
# - AEMO, [Market Ancillary Service Specification](https://www.aemo.com.au/energy-systems/electricity/national-electricity-market-nem/system-operations/ancillary-services/market-ancillary-service-specification-and-fcas-verification-tool): delivery and measurement.
# - AEMO, [Constraint Formulation Guidelines, v13](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/constraint-formulation-guidelines.pdf), §5: FCAS requirements.
# - AEMO, [MMS Data Model Report](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/): column definitions.
#
# ## [Where the data lives](@id fcas-types-mapping)
#
# The **Table** column is the MMSDM table and the cache directory; see
# [the cache layout](@ref nemde-data). `<SERVICE>` stands for one of the ten market names,
# such as `RAISE6SEC`.
#
# | Symbol | Quantity | Table | Columns | Time key | Role |
# | --- | --- | --- | --- | --- | --- |
# | ``c_{u,j,b}`` | Band prices | `BIDDAYOFFER_D` | `PRICEBAND1` to `PRICEBAND10`, with `BIDTYPE = <SERVICE>` and `DIRECTION` | Trading day | Input |
# | ``Q_{u,j,b}`` | Band quantities | `BIDPEROFFER_D` | `BANDAVAIL1` to `BANDAVAIL10`, with `BIDTYPE = <SERVICE>` and `DIRECTION` | Trading day and interval end (`INTERVAL_DATETIME`) | Input |
# | ``E^{\min}``, ``B^{\mathrm{lo}}``, ``B^{\mathrm{hi}}``, ``E^{\max}``, ``F`` | Trapezium as offered | `BIDPEROFFER_D` | `ENABLEMENTMIN`, `LOWBREAKPOINT`, `HIGHBREAKPOINT`, `ENABLEMENTMAX`, `MAXAVAIL` | Trading day and interval end | Input |
# | | Energy availability of a battery, per side | `BIDPEROFFER_D` | `MAXAVAIL`, with `BIDTYPE = ENERGY` | Trading day and interval end | Input |
# | | Unit region, type and connection point | `DUDETAILSUMMARY` | `DUID`, `REGIONID`, `DISPATCHTYPE`, `SCHEDULE_TYPE`, `CONNECTIONPOINTID` | Effective date (`START_DATE`, `END_DATE`) | Input |
# | ``p^0`` | Metered starting output | `DISPATCHLOAD` | `INITIALMW` | Interval end | Input |
# | | Energy availability | `DISPATCHLOAD` | `AVAILABILITY` | Interval end | Input |
# | ``\mathrm{UIGF}`` | Wind and solar forecast | `DISPATCHLOAD` | `UIGF` | Interval end | Input |
# | ``E^{\mathrm{AGC}}_{\min}``, ``E^{\mathrm{AGC}}_{\max}`` | AGC limits for regulation | `DISPATCHLOAD` | `RAISEREGENABLEMENTMIN`, `RAISEREGENABLEMENTMAX`, `LOWERREGENABLEMENTMIN`, `LOWERREGENABLEMENTMAX` | Interval end | Input |
# | ``R^{\mathrm{AGC}\uparrow}``, ``R^{\mathrm{AGC}\downarrow}`` | Ramp rates, MW per hour | `DISPATCHLOAD` | `RAMPUPRATE`, `RAMPDOWNRATE` | Interval end | Input |
# | | AGC status: 1 is on AGC | `DISPATCHLOAD` | `AGCSTATUS` | Interval end | Input |
# | ``g`` | Requirements active in the interval, and the version in force | `DISPATCHCONSTRAINT` | `CONSTRAINTID`, `GENCONID_EFFECTIVEDATE`, `GENCONID_VERSIONNO` | Interval end | Input |
# | ``b_g`` | Right-hand side of a requirement | `DISPATCHCONSTRAINT` | `RHS` | Interval end | Result, used as input |
# | | Sense and penalty factor of a requirement | `GENCONDATA` | `CONSTRAINTTYPE`, `GENERICCONSTRAINTWEIGHT` | Effective date (`EFFECTIVEDATE`, `VERSIONNO`) | Input |
# | ``w_{g,u,j}``, ``w_{g,u}`` | Unit coefficients | `SPDCONNECTIONPOINTCONSTRAINT` | `CONNECTIONPOINTID`, `BIDTYPE`, `FACTOR` | Effective date | Input |
# | | Regional coefficients | `SPDREGIONCONSTRAINT` | `REGIONID`, `BIDTYPE`, `FACTOR` | Effective date | Input |
# | ``w_{g,i}`` | Interconnector coefficients | `SPDINTERCONNECTORCONSTRAINT` | `INTERCONNECTORID`, `FACTOR` | Effective date | Input |
# | | Which region and service each requirement covers | `DISPATCH_FCAS_REQ`, or `DISPATCH_FCAS_REQ_CONSTRAINT` from the June 2025 archive | `GENCONID` or `CONSTRAINTID`, `REGIONID`, `BIDTYPE`, `MARGINALVALUE` | Interval end (`SETTLEMENTDATE` or `INTERVAL_DATETIME`) | Result |
# | ``f_{u,j}`` | Enablement | `DISPATCHLOAD` | `<SERVICE>` | Interval end | Result |
# | | Actual availability | `DISPATCHLOAD` | `<SERVICE>ACTUALAVAILABILITY` | Interval end | Result |
# | ``\tilde p`` | Energy target | `DISPATCHLOAD` | `TOTALCLEARED` | Interval end | Result |
# | ``\mu_g`` | Marginal value and left-hand side of a requirement | `DISPATCHCONSTRAINT` | `MARGINALVALUE`, `LHS` | Interval end | Result |
# | | Service price in a region | `DISPATCHPRICE` | `<SERVICE>ROP`, `<SERVICE>RRP`, `<SERVICE>APCFLAG` | Interval end | Result |
#
# Three points need care when reading these tables.
#
# - The limits and rates in `DISPATCHLOAD` are the ones dispatch used: the more restrictive
#   of what the unit offered and what its telemetry reported. The raw telemetry is not
#   published there.
# - `RAISEREGAVAILABILITY` and `LOWERREGAVAILABILITY` in `DISPATCHLOAD` are results, like
#   actual availability. The offered amount is `MAXAVAIL` in `BIDPEROFFER_D`.
# - A requirement is defined by its coefficient rows, not by its name or its right-hand side.
#   The rows are matched by identifier, effective date and version, and can sit in an archive
#   month long before the interval.
