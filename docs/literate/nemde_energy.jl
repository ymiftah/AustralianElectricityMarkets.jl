using CairoMakie #hide

# # [Energy bids and participants](@id nemde-energy)
#
# This chapter covers the energy side of dispatch: how participants offer, how offer prices
# are made comparable across a region, what limits each unit's output, and how supply meets
# demand in each region. Symbols follow the [notation table](@ref nemde-notation).
#
# ## Who offers energy
#
# Three kinds of participant submit energy offers.
#
# - **Scheduled and semi-scheduled generators** offer to produce.
# - **Scheduled loads**, such as pumped-hydro pumps, bid to consume.
# - **Bidirectional units**, in practice batteries, submit both an offer to generate and a bid
#   to consume.
#
# Everything else, including rooftop solar and small generators, is non-scheduled. It takes
# no part in the optimisation and reaches it only through the demand forecast.
#
# ## The offer
#
# An energy offer has ten **price bands**. Its prices are set once per trading day and must
# not decrease from band 1 to band 10. Its quantities, the MW placed in each band, are set per
# five-minute interval and can be rebid until shortly before dispatch. A participant
# therefore moves volume between fixed prices instead of changing the prices themselves.
#
# NEMDE clears part of each band. Write ``q^d_{u,b}`` for the MW cleared from band ``b`` of
# unit ``u`` in direction ``d``, where ``d`` is `GEN` for generation and `LOAD` for
# consumption, and ``Q^d_{u,b}`` for the MW offered:
#
# ```math
# 0\le q^d_{u,b}\le Q^d_{u,b},\qquad
# p^{\mathrm{out}}_u=\sum_bq^{\mathrm{GEN}}_{u,b},\qquad
# p^{\mathrm{in}}_u=\sum_bq^{\mathrm{LOAD}}_{u,b}.
# ```
#
# The cleared bands add up to the unit's generation ``p^{\mathrm{out}}_u`` or consumption
# ``p^{\mathrm{in}}_u``. Both are non-negative. The unit's net injection is
# ``p_u=p^{\mathrm{out}}_u-p^{\mathrm{in}}_u``.
#
# ## Prices are compared at the regional reference node
#
# A region has one price, defined at its regional reference node. Units sit elsewhere in the
# network, and power is lost on the way. Each connection point therefore has a **loss
# factor** ``\mathrm{LF}_u``, fixed for the financial year. It is the product of a
# transmission loss factor, also called the marginal loss factor (MLF), and a distribution
# loss factor (DLF). A factor of 0.95 means that 1 MW at the unit is worth 0.95 MW at the
# reference node.
#
# Before the optimisation, each band price is divided by the loss factor:
#
# ```math
# \widehat c^d_{u,b}=\frac{c^d_{u,b}}{\mathrm{LF}^d_u}.
# ```
#
# A generator offering at \$50/MWh with a loss factor of 0.95 competes at \$52.63/MWh. Only
# the price is adjusted. The offered MW are unchanged. A bidirectional unit can have a
# different loss factor for generation and for consumption. FCAS offers are not adjusted.
# NEMDE's published case files carry the adjusted prices rounded to the cent. AEMO explains
# the adjustment in
# [Treatment of Loss Factors in the NEM, §12, pp. 25-28](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2016/treatment_of_loss_factors_in_the_nem.pdf).
#
# The energy part of the objective is the cost of cleared generation less the value of
# cleared consumption, over an interval of ``h`` hours:
#
# ```math
# C_E=h\left(\sum_{u,b}\widehat c^{\mathrm{GEN}}_{u,b}\,q^{\mathrm{GEN}}_{u,b}
# -\sum_{u,b}\widehat c^{\mathrm{LOAD}}_{u,b}\,q^{\mathrm{LOAD}}_{u,b}\right).
# ```
#
# A consumption bid states what the load is willing to pay. Clearing it lowers the objective,
# so a load is dispatched when the regional price is below its bid.
#
# ## What limits a unit
#
# ### Availability
#
# Each interval the participant declares a maximum availability, the most the unit can
# produce. For a semi-scheduled unit AEMO also supplies the UIGF, its own forecast of what the
# wind or sun allows. The target must respect both:
#
# ```math
# p_u-\sigma_u^{\mathrm{avail}}\le A_u,\qquad
# p_u-\sigma_u^{\mathrm{uigf}}\le \mathrm{UIGF}_u\quad\text{(semi-scheduled units)}.
# ```
#
# The slacks ``\sigma`` are zero in almost every interval. They exist so that the problem
# always has a solution, and they are priced high enough to be a last resort. See
# [Violations, tie-breaking and prices](@ref nemde-prices).
#
# ### Ramp rates
#
# A unit can move only so far in five minutes. The limit is measured from its metered output
# at the start of the interval, ``p^0_u``, not from the target it was given for the previous
# interval:
#
# ```math
# p_u-p^0_u-\sigma_u^{\uparrow}\le R_u^{\uparrow}h,\qquad
# p^0_u-p_u-\sigma_u^{\downarrow}\le R_u^{\downarrow}h.
# ```
#
# ``R^{\uparrow}_u`` and ``R^{\downarrow}_u`` are the lower of the rate the participant
# offered and the rate its telemetry reports. A unit metered at 100 MW with ramp rates of
# 120 MW per hour can be sent anywhere from 90 to 110 MW.
#
# Availability and ramp limits can contradict each other. A unit metered at 100 MW that
# declares 60 MW available, with 10 MW of downward ramp, cannot satisfy both. NEMDE then
# violates the cheaper constraint. The penalty factors are 1155 for ramp rates, 385 for the
# UIGF and 370 for availability, so the unit is held at 90 MW, above its declared
# availability. The factors are items 3, 12 and 14 of AEMO's
# [Schedule of Constraint Violation Penalty Factors, v8.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf).
#
# !!! note "Deviation in AustralianElectricityMarketsSimulations"
#     **AEMO:** availability and the UIGF are constraints with their own priced violation.
#     **This package:** both are hard upper limits with no violation variable. To reproduce
#     the outcome above, the upper limit is raised to the ramp-down floor,
#     ``\max(A_u,\;p^0_u-R^{\downarrow}_uh)``, before the solve. The result matches when the
#     ramp limit is the only reason to exceed availability, and differs if NEMDE exceeds
#     availability for any other reason.
#
# ## Batteries
#
# A bidirectional unit has two offers and two availabilities, one per direction:
#
# ```math
# p_u=p_u^{\mathrm{out}}-p_u^{\mathrm{in}},\qquad
# 0\le p_u^{\mathrm{out}}\le A_u^{\mathrm{GEN}},\qquad
# 0\le p_u^{\mathrm{in}}\le A_u^{\mathrm{LOAD}}.
# ```
#
# Its ramp limits apply to the net injection ``p_u``, measured from the metered net injection
# ``p^0_u``. A battery can therefore go from charging to discharging within one interval, as
# long as the total movement is within its ramp rate.

let #hide
    fig = Figure(size = (800, 300)) #hide
    ax = Axis(fig[1, 1]; xlabel = "Net injection (MW)", ylabel = "", title = "Illustrative battery limits for one interval", yticks = (1:2, ["Availability", "Reachable by ramping"])) #hide
    lines!(ax, [-80, 100], [1, 1]; color = :gray, linewidth = 12) #hide
    lines!(ax, [-20, 40], [2, 2]; color = :steelblue, linewidth = 12) #hide
    vlines!(ax, [10]; color = :darkorange, linestyle = :dash, label = "Metered at interval start: 10 MW") #hide
    axislegend(ax; position = :rb) #hide
    ylims!(ax, 0.5, 2.6) #hide
    fig #hide
end #hide

# *Constructed example. The battery can generate up to 100 MW and consume up to 80 MW. It is
# metered at 10 MW and can move 30 MW in five minutes, so its target lies between -20 and
# 40 MW. The range crosses zero.*
#
# Five-minute dispatch does not track the energy stored in a battery. The participant manages
# it through the quantities it offers in each direction. AEMO checks stored energy only in
# its half-hourly forecast runs
# ([FCAS Model in NEMDE, §5, pp. 18-19](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf)).
#
# !!! note "Deviation in AustralianElectricityMarketsSimulations"
#     **AEMO:** the published documents do not say how NEMDE rules out clearing generation
#     and consumption bands of one battery in the same interval. **This package:** has no
#     such rule. If both directions clear, only the net injection is meaningful.
#
# ## Supply meets demand in each region
#
# The sign of each participant's contribution to its region is as follows.
#
# | Participant | What it offers | Net injection |
# | --- | --- | --- |
# | Generator | Generation ``p^{\mathrm{out}}`` | ``+p^{\mathrm{out}}`` |
# | Scheduled load | Consumption ``p^{\mathrm{in}}`` | ``-p^{\mathrm{in}}`` |
# | Battery | Generation and consumption | ``p^{\mathrm{out}}-p^{\mathrm{in}}`` |
# | Load that offers FCAS only | Nothing in the energy market | Zero. Its consumption is part of demand |
#
# Each region has one energy balance:
#
# ```math
# \sum_{u\in r}p_u+\sum_i I_{r,i}+\sigma_r^{\mathrm{def}}-\sigma_r^{\mathrm{sur}}=D_r.
# ```
#
# The first term is the net injection of the region's units. ``I_{r,i}`` is what
# interconnector ``i`` delivers to region ``r`` after losses, negative for an export; see
# [Interconnectors and losses](@ref nemde-interconnectors). ``D_r`` is AEMO's forecast of the
# region's demand at the end of the interval. It excludes scheduled loads and batteries,
# whose consumption is decided by the optimisation and sits on the left. The two slacks let
# the region fall short of demand or exceed it, at a penalty factor of 150. FCAS enablement
# is reserve capacity. It adds no energy to the balance.
#
# The marginal value of this constraint, ``\lambda_r``, is the regional energy price.
#
# !!! note "Deviation in AustralianElectricityMarketsSimulations"
#     **AEMO:** ``D_r`` is a forecast made before the solve. **This package:** ``D_r`` is the
#     published `TOTALDEMAND` of the interval, which AEMO reports after the solve as demand
#     net of dispatched scheduled load. The balance therefore reproduces the published
#     regional requirement. It does not test the demand forecast.
#
# !!! note "Deviation in AustralianElectricityMarketsSimulations"
#     **AEMO:** wholesale demand response units are dispatched like other units. **This
#     package:** they are not modelled, and their response is absent from the balance.
#
# ## A worked example
#
# One region has a demand of 250 MW, no interconnector and two generators.
#
# | Generator | Offered | Price at the unit | Loss factor | Price at the reference node |
# | --- | --- | --- | --- | --- |
# | G1 | 100 MW | \$30/MWh | 1.00 | \$30.00/MWh |
# | G2 | 200 MW | \$50/MWh | 0.95 | \$52.63/MWh |
#
# G1 is cheaper and clears in full. G2 supplies the remaining 150 MW. One more MW of demand
# would come from G2, so the regional price is \$52.63/MWh. G2 is paid that price times its
# loss factor, which is the \$50/MWh it offered. G1 is paid \$52.63/MWh.
#
# ## References
#
# - AEMO, [Treatment of Loss Factors in the NEM](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2016/treatment_of_loss_factors_in_the_nem.pdf), §12: price adjustment to the reference node.
# - AEMO, [Dispatch Procedure](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/power_system_ops/procedures/so_op_3705-dispatch.pdf): dispatch inputs, availability and ramp rates.
# - AEMO, [Schedule of Constraint Violation Penalty Factors, v8.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf), items 3, 12, 14, 22 and 23.
# - AEMO, [MMS Data Model Report](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/): column definitions.
#
# ## [Where the data lives](@id nemde-energy-data)
#
# The **Table** column is the MMSDM table and the cache directory; see
# [the cache layout](@ref nemde-data).
#
# | Symbol | Quantity | Table | Columns | Time key | Role |
# | --- | --- | --- | --- | --- | --- |
# | ``c^d_{u,b}`` | Band prices | `BIDDAYOFFER_D` | `PRICEBAND1` to `PRICEBAND10`, with `BIDTYPE = ENERGY` and `DIRECTION` | Trading day | Input |
# | ``Q^d_{u,b}`` | Band quantities | `BIDPEROFFER_D` | `BANDAVAIL1` to `BANDAVAIL10`, with `BIDTYPE = ENERGY` and `DIRECTION` | Trading day and interval end (`INTERVAL_DATETIME`) | Input |
# | ``A^{\mathrm{GEN}}_u``, ``A^{\mathrm{LOAD}}_u`` | Offered availability per direction | `BIDPEROFFER_D` | `MAXAVAIL` | Trading day and interval end | Input |
# | ``A_u`` | Availability used in dispatch | `DISPATCHLOAD` | `AVAILABILITY` | Interval end | Input |
# | ``\mathrm{UIGF}_u`` | Wind and solar forecast | `DISPATCHLOAD` | `UIGF` | Interval end | Input |
# | ``p^0_u`` | Metered starting output | `DISPATCHLOAD` | `INITIALMW` | Interval end | Input |
# | ``R^{\uparrow}_u``, ``R^{\downarrow}_u`` | Ramp rates, MW per hour | `DISPATCHLOAD` | `RAMPUPRATE`, `RAMPDOWNRATE` | Interval end | Input |
# | ``\mathrm{LF}_u`` | Loss factor | `DUDETAILSUMMARY` | `TRANSMISSIONLOSSFACTOR`, `DISTRIBUTIONLOSSFACTOR`; `SECONDARY_TLF` for a battery's consumption | Effective date (`START_DATE`, `END_DATE`) | Input |
# | | Unit region and type | `DUDETAILSUMMARY` | `DUID`, `REGIONID`, `DISPATCHTYPE`, `SCHEDULE_TYPE` | Effective date | Input |
# | ``D_r`` | Regional demand | `DISPATCHREGIONSUM` | `TOTALDEMAND` | Interval end | Result, used as input |
# | ``p_u`` | Energy target | `DISPATCHLOAD` | `TOTALCLEARED` | Interval end | Result |
# | ``\lambda_r`` | Regional energy price | `DISPATCHPRICE` | `ROP`, `RRP` | Interval end | Result |
#
# `BIDDAYOFFER_D` and `BIDPEROFFER_D` hold the offer that was applied in dispatch, one per
# unit, market and direction. They do not hold the history of rebids. The dispatch tables
# are also keyed by `INTERVENTION`, which is 0 except during an intervention; see
# [Violations, tie-breaking and prices](@ref nemde-prices-data).
