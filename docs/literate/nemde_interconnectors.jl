using CairoMakie #hide

# # [Interconnectors and losses](@id nemde-interconnectors)
#
# The five NEM regions are joined by a small number of transfer paths. NEMDE does not model
# the lines inside a region. It models each path between two regions as one
# **interconnector** with a single flow variable, and accounts for the power lost on the way.
# This chapter explains the flow limits, the loss model, how losses are split between the
# two regions, and the special case of an interconnector that offers its capacity at a price.
# Symbols follow the [notation table](@ref nemde-notation).
#
# ## The interconnectors
#
# | Identifier | Joins | Common name |
# | --- | --- | --- |
# | `NSW1-QLD1` | New South Wales and Queensland | QNI |
# | `N-Q-MNSP1` | New South Wales and Queensland | Terranora |
# | `VIC1-NSW1` | Victoria and New South Wales | VNI |
# | `V-SA` | Victoria and South Australia | Heywood |
# | `V-S-MNSP1` | Victoria and South Australia | Murraylink |
# | `T-V-MNSP1` | Tasmania and Victoria | Basslink |
#
# Each interconnector has a defined direction, from one region to the other. Its flow
# ``x_i`` is positive in that direction and negative against it.
#
# Most interconnectors are **regulated**: they earn a regulated revenue, offer nothing into
# the market, and NEMDE is free to set their flow. A **market network service provider
# (MNSP)** instead offers transfer capacity at a price, like a generator. Basslink has been
# the only interconnector to do so. Terranora and Murraylink carry "MNSP" in their
# identifiers for historical reasons and are regulated. AEMO's 2026-27 loss factor report
# records Basslink's notice to stop operating as an MNSP from 1 July 2026.
#
# ## Flow limits
#
# Each interconnector has an export limit ``\overline x_i`` in its defined direction and an
# import limit ``\underline x_i`` against it. The import limit is a negative number:
#
# ```math
# x_i-\sigma_i^{\mathrm{sur}}\le \overline x_i,\qquad
# x_i+\sigma_i^{\mathrm{def}}\ge \underline x_i.
# ```
#
# The slacks ``\sigma`` allow a limit to be exceeded at a penalty factor of 1150, item 5 of
# AEMO's [Schedule of Constraint Violation Penalty Factors, v8.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf).
# In practice the binding limits on an interconnector usually come from generic constraints,
# which combine its flow with the output of nearby units; see
# [Violations, tie-breaking and prices](@ref nemde-prices).
#
# ## Losses
#
# ### The loss equation
#
# Power is lost in transit, and the loss grows faster than the flow. Each year AEMO
# publishes, for each interconnector, a **marginal loss factor** equation: the loss caused
# by one more MW of flow, as a linear function of the flow and of regional demand:
#
# ```math
# \mathrm{MLF}_i(x)=k_i+m_i\,x+\sum_rd_{i,r}D_r.
# ```
#
# ``k_i`` is a constant close to 1, ``m_i`` is the flow coefficient, and ``d_{i,r}`` are
# demand coefficients for the regions whose demand affects this interconnector. A value of
# 1.04 means that the next MW sent loses 0.04 MW.
#
# The total loss is the marginal loss, ``\mathrm{MLF}_i-1``, added up from zero flow:
#
# ```math
# L_i(x)=\int_0^x\big(\mathrm{MLF}_i(y)-1\big)\,dy
# =\Big(k_i-1+\sum_rd_{i,r}D_r\Big)x+\tfrac12m_i\,x^2.
# ```
#
# The loss is zero at zero flow and quadratic in the flow. AEMO states this integration in
# its [Marginal Loss Factors for 2025-26, §4, p. 60](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en).
# The demand ``D_r`` here is the region's demand at the start of the interval plus the
# forecast change over the interval. These interconnector loss equations are separate from
# the per-unit loss factors that adjust offer prices in
# [Energy bids and participants](@ref nemde-energy).
#
# ### A piecewise-linear curve
#
# A linear programme cannot hold a quadratic term, so the curve is replaced by straight
# segments between published **breakpoints** ``X_{i,0}<X_{i,1}<\dots`` on the flow axis.
# Write ``\ell_{i,n}=L_i(X_{i,n})`` for the loss at breakpoint ``n``. Between two adjacent
# breakpoints the loss follows the chord:
#
# ```math
# L_i(x)=\ell_{i,n-1}+\frac{\ell_{i,n}-\ell_{i,n-1}}{X_{i,n}-X_{i,n-1}}\,(x-X_{i,n-1}),
# \qquad X_{i,n-1}\le x\le X_{i,n}.
# ```
#
# The slope of each chord approximates the marginal loss on that segment. Because the true
# curve is convex, a chord lies above it everywhere between its two ends. A chord that
# spans zero flow therefore shows a small positive loss at zero flow.
#
# !!! note "Deviation in AustralianElectricityMarketsSimulations"
#     **AEMO:** the loss equation is defined by integration from zero flow. The published
#     documents do not say how the breakpoint values are placed. **This package:** when a
#     chord spans zero flow, every breakpoint value is lowered by that chord's value at zero,
#     so the curve passes through zero. Slopes, and therefore marginal losses, are unchanged.

let #hide
    xs = range(-100, 200; length = 301) #hide
    analytic = 0.0005 .* xs .^ 2 #hide
    bps = [-100.0, 100.0, 200.0] #hide
    vertices = 0.0005 .* bps .^ 2 #hide
    fig = Figure(size = (800, 330)) #hide
    ax = Axis(fig[1, 1]; xlabel = "Flow (MW)", ylabel = "Loss (MW)", title = "Illustrative loss curve and its piecewise-linear forms") #hide
    lines!(ax, xs, analytic; color = :gray, linewidth = 2, label = "Quadratic loss equation") #hide
    lines!(ax, bps, vertices; color = :darkorange, linewidth = 3, label = "Chords between breakpoints") #hide
    lines!(ax, bps, vertices .- 5; color = :steelblue, linewidth = 3, label = "Chords shifted to zero at zero flow") #hide
    vlines!(ax, [0]; color = (:black, 0.2), linestyle = :dash) #hide
    axislegend(ax; position = :lt, labelsize = 12) #hide
    fig #hide
end #hide

# *Constructed coefficients. The chord from -100 to 100 MW reads 5 MW at zero flow.
# Subtracting 5 MW from every breakpoint value moves the curve down and keeps its slopes.*
#
# The piecewise curve is correct only if its segments are used in order: a flow of 150 MW
# must fill the first segment before the second. When energy is valuable the optimisation
# does this by itself, because the low-loss segments are the cheapest. When the price is
# negative it would rather pick the high-loss segments first and so discard energy.
#
# !!! note "Deviation in AustralianElectricityMarketsSimulations"
#     **AEMO:** the published documents do not describe how NEMDE enforces segment order.
#     **This package:** integer variables force the segments to fill in order, which makes
#     the problem a mixed-integer programme. Prices are taken from a second solve with those
#     integers fixed. The first and last breakpoints also bound the flow as hard limits,
#     whatever the flow-limit slacks allow.
#
# ### Who supplies the losses
#
# The losses must be generated somewhere. For a regulated interconnector, a fixed share
# ``\rho_i`` is assigned to the region the flow is defined from and the rest to the other
# region. Each region's energy balance receives:
#
# ```math
# I_{\mathrm{from},i}=-x_i-\rho_i\,L_i,\qquad
# I_{\mathrm{to},i}=x_i-(1-\rho_i)\,L_i.
# ```
#
# The sending region gives up the flow and its share of the loss. The receiving region gains
# the flow less its share. The two terms sum to ``-L_i``: the interconnector consumes its
# losses.
#
# ### What losses do to prices
#
# Losses are why two connected regions have different prices even when no limit binds.
# Suppose the marginal loss at the current flow is ``\ell'=dL_i/dx``. Sending one more MW
# costs the sending region ``1+\rho\,\ell'`` MW and delivers ``1-(1-\rho)\,\ell'`` MW. With
# no binding limit on the interconnector, the two regional prices settle where that trade
# breaks even:
#
# ```math
# \lambda_{\mathrm{from}}\,(1+\rho\,\ell')=\lambda_{\mathrm{to}}\,\big(1-(1-\rho)\,\ell'\big).
# ```
#
# With a marginal loss of 0.04, an even split ``\rho=0.5`` and a sending price of \$50/MWh,
# the receiving price is ``50\times1.02/0.98`` = \$52.04/MWh. When a flow limit or a generic
# constraint binds, the prices separate further and this relation no longer holds.
#
# ## An interconnector that offers its capacity
#
# An MNSP submits two offers, one for each direction of flow. Each has ten price bands
# fixed for the trading day and band quantities per interval, like an energy offer. Write
# ``q^d_{i,b}`` for the MW cleared from band ``b`` in direction ``d``, ``Q^d_{i,b}`` for the
# MW offered and ``A^d_i`` for the offered availability:
#
# ```math
# q^d_i=\sum_bq^d_{i,b},\qquad 0\le q^d_{i,b}\le Q^d_{i,b},\qquad q^d_i\le A^d_i,\qquad
# x_i=q^{\mathrm{fwd}}_i-q^{\mathrm{rev}}_i.
# ```
#
# The accepted bands cost ``h\sum_{d,b}c^d_{i,b}\,q^d_{i,b}`` in the objective. An MNSP band
# clears when the price difference between the two regions is at least its offer price. The
# offer is, in effect, the fee for moving energy across.
#
# The flow ``q^d_i`` is measured at the receiving end. The sending end supplies the flow
# plus the whole loss, and each end is referred to its regional reference node by a loss
# factor of its own:
#
# ```math
# I_{\mathrm{send},i}=-\mathrm{LF}^{\mathrm{send}}_i\,(q^d_i+L_i),\qquad
# I_{\mathrm{recv},i}=\mathrm{LF}^{\mathrm{recv}}_i\,q^d_i.
# ```
#
# When the flow reverses, the sending and receiving regions swap, so the loss always falls
# on the region that is exporting. AEMO describes this convention in its
# [Marginal Loss Factors for 2025-26, §5.1, p. 63](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en).
#
# AEMO's penalty schedule also gives an MNSP a ramp-rate limit (item 4, factor 1155), and
# priced violations of its total offer (item 9, factor 1135), its availability (item 16,
# factor 365) and its loss equations (item 17, factor 365).
#
# !!! note "Deviation in AustralianElectricityMarketsSimulations"
#     **AEMO:** MNSP availability and offer limits can be violated at a penalty, the flow is
#     ramp-limited, and a fixed loading can be offered. **This package:** availability and
#     band quantities are hard limits, and the ramp rate and fixed loading are not modelled.
#     An integer variable allows only one direction to flow in an interval.
#
# !!! note "Deviation in AustralianElectricityMarketsSimulations"
#     **AEMO:** Basslink has fixed converter losses and cannot operate in a band of low flows
#     around zero. **This package:** neither is modelled. When Basslink has no offers in the
#     data, it is treated as a free-flowing interconnector with all of its losses assigned to
#     Tasmania, in place of the zero share published for it.
#
# ## A worked example
#
# An interconnector has ``k=1.0``, no demand terms, ``m=0.0004`` per MW and breakpoints at
# 0, 100 and 200 MW. The loss equation gives ``L(x)=0.0002\,x^2``, so the breakpoint losses
# are 0, 2 and 8 MW. The first segment has a slope of 0.02 and the second a slope of 0.06.
#
# At a flow of 150 MW the piecewise loss is ``2+0.06\times50`` = 5 MW. The quadratic gives
# 4.5 MW; the chord overstates it slightly. With an even split, the sending region's balance
# receives ``-150-2.5`` = -152.5 MW and the receiving region's ``150-2.5`` = 147.5 MW. On
# this segment, a sending price of \$50/MWh implies a receiving price of
# ``50\times1.03/0.97`` = \$53.09/MWh.
#
# ## References
#
# - AEMO, [Marginal Loss Factors for the 2025-26 Financial Year](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en), §§3-5: loss equations, integration and Basslink.
# - AEMO, [Schedule of Constraint Violation Penalty Factors, v8.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf), items 4, 5, 9, 16 and 17.
# - AEMO, [MMS Data Model Report](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/): column definitions.
# - [Loss inputs and assumptions](../interconnector-losses.md): yearly loss equations and
#   changes of network configuration.
#
# ## [Where the data lives](@id nemde-interconnectors-data)
#
# The **Table** column is the MMSDM table and the cache directory; see
# [the cache layout](@ref nemde-data).
#
# | Symbol | Quantity | Table | Columns | Time key | Role |
# | --- | --- | --- | --- | --- | --- |
# | | Regions joined and direction | `INTERCONNECTOR` | `INTERCONNECTORID`, `REGIONFROM`, `REGIONTO` | None, one row per interconnector | Input |
# | ``k_i``, ``m_i`` | Loss equation constant and flow coefficient | `INTERCONNECTORCONSTRAINT` | `LOSSCONSTANT`, `LOSSFLOWCOEFFICIENT` | Effective date (`EFFECTIVEDATE`, `VERSIONNO`) | Input |
# | ``\rho_i`` | Loss share of the from region | `INTERCONNECTORCONSTRAINT` | `FROMREGIONLOSSSHARE` | Effective date | Input |
# | ``d_{i,r}`` | Demand coefficients | `LOSSFACTORMODEL` | `REGIONID`, `DEMANDCOEFFICIENT` | Effective date | Input |
# | ``X_{i,n}`` | Flow breakpoints | `LOSSMODEL` | `LOSSSEGMENT`, `MWBREAKPOINT` | Effective date | Input |
# | ``D_r`` | Demand in the loss equation | `DISPATCHREGIONSUM` | `INITIALSUPPLY` + `DEMANDFORECAST` | Interval end | Input |
# | | Battery charging at the start, removed from ``D_r`` | `DISPATCHLOAD` | `INITIALMW` of bidirectional units | Interval end | Input |
# | ``\overline x_i``, ``\underline x_i`` | Flow limits | `DISPATCHINTERCONNECTORRES` | `EXPORTLIMIT`, `IMPORTLIMIT` | Interval end | Result, used as input |
# | ``c^d_{i,b}`` | MNSP band prices | `MNSP_DAYOFFER` | `LINKID`, `PRICEBAND1` to `PRICEBAND10` | Trading day | Input |
# | ``Q^d_{i,b}``, ``A^d_i`` | MNSP band quantities and availability | `MNSP_BIDOFFERPERIOD` | `LINKID`, `PERIODID`, `BANDAVAIL1` to `BANDAVAIL10`, `MAXAVAIL` | Trading day and period (`TRADINGDATE`, `PERIODID`) | Input |
# | ``\mathrm{LF}^{\mathrm{send}}_i``, ``\mathrm{LF}^{\mathrm{recv}}_i`` | MNSP loss factors at each end | `MNSP_INTERCONNECTOR` | `LINKID`, `FROM_REGION_TLF`, `TO_REGION_TLF` | Effective date | Input |
# | ``x_i``, ``L_i`` | Flow and losses | `DISPATCHINTERCONNECTORRES` | `MWFLOW`, `MWLOSSES` | Interval end | Result |
#
# An MNSP's two directions are stored as two **links**, each with its own `LINKID` and its
# own from and to region. Older archives hold MNSP quantities in `MNSP_PEROFFER` instead of
# `MNSP_BIDOFFERPERIOD`. Loss equations are revised each financial year, on 1 July.
