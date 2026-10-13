using CairoMakie #hide

# # [Interconnectors and losses](@id nemde-interconnectors)
#
# An interconnector carries signed flow ``x_i`` from its configured `from` region to its `to`
# region. Ordinary regulated transfers have no energy-offer curve of their own; paired MNSP
# links have directional offers. Losses modify each region's energy balance.
#
# ## Flow bounds and analytic losses
#
# The interconnector limit rows are
#
# ```math
# x_i-s_i^{sur}\le U_i,\qquad x_i+s_i^{def}\ge -V_i.
# ```
#
# The flow-limit slacks have factor 1150 in the
# [CVP schedule v8.0, item 5](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf).
#
# With regional demand inputs ``D_r``, the resolved loss-factor equation and its integral are
#
# ```math
# \mathrm{LF}_i(x,D)=c_i+m_i x+\sum_rd_{i,r}D_r,\qquad
# L_i^{analytic}(x,D)=\left(c_i-1+\sum_rd_{i,r}D_r\right)x+\frac12m_ix^2.
# ```
#
# `LOSSCONSTANT` is a factor relative to unity, hence the subtraction of 1. AEMO describes the
# integral in [FY2025-26 Marginal Loss Factors, §4, p. 60](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en).
# These are inter-regional loss equations, distinct from a unit's energy-bid loss-factor referral.
#
# ## Piecewise loss curves
#
# AEMO publishes flow breakpoints in `LOSSMODEL` for the linear-programming representation
# of interconnector losses ([Electricity Data Model Report](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/)).
# For adjacent breakpoints ``B_{j-1}`` and ``B_j`` with losses ``V_{j-1}`` and ``V_j``,
# the chord is
#
# ```math
# L^{chord}(x)=V_{j-1}+\frac{V_j-V_{j-1}}{B_j-B_{j-1}}(x-B_{j-1}),
# \qquad B_{j-1}\le x\le B_j.
# ```
#
# Chord slopes approximate marginal losses. Interpolating analytic losses at breakpoints
# need not preserve zero loss at zero flow when a segment spans zero.
#
# !!! note "Discrete curve anchoring"
#     Shifting all vertices by ``-L^{chord}(0)`` preserves slopes and anchors the chord
#     at zero flow. This is a reconstruction assumption: the annual integration rule
#     does not specify the interpolation procedure. The replica does not apply this
#     discrete zero-flow correction, so a chord spanning zero can retain a loss offset.
#
let #hide
    xs = range(-100, 200; length = 301) #hide
    analytic = 0.0005 .* xs .^ 2 #hide
    bps = [-100.0, 100.0, 200.0] #hide
    vertices = 0.0005 .* bps .^ 2 #hide
    fig = Figure(size = (800, 330)) #hide
    ax = Axis(fig[1, 1]; xlabel = "Signed flow (MW)", ylabel = "Loss (MW)", title = "Illustrative zero-flow chord correction") #hide
    lines!(ax, xs, analytic; color = :gray, linewidth = 2, label = "Analytic integral") #hide
    lines!(ax, bps, vertices; color = :darkorange, linewidth = 3, label = "Unshifted chords") #hide
    lines!(ax, bps, vertices .- 5; color = :steelblue, linewidth = 3, label = "Anchored chords") #hide
    vlines!(ax, [0]; color = (:black, 0.2), linestyle = :dash) #hide
    axislegend(ax; position = :lt, labelsize = 12) #hide
    fig #hide
end #hide

# *Constructed coefficients: the chord from -100 to 100 MW has a 5 MW intercept. Subtracting
# it from all vertices changes the loss level while retaining the chord slopes.*
#
# ## Regional loss sharing
#
# With configured from-region loss share ``\sigma_i``, injections are
#
# ```math
# I_{from,i}=-x_i-\sigma_iL_i,\qquad
# I_{to,i}=x_i-(1-\sigma_i)L_i.
# ```
#
# These sum to ``-L_i``. In an uncongested, locally linear, hard-balance case, a marginal
# forward transfer with loss slope ``m`` gives
# ``\lambda_{from}(1+\sigma m)=\lambda_{to}(1-(1-\sigma)m)``. This is a special-case
# marginal balance identity, not the price relation when a generic constraint binds or the
# directional terminal-factor allocation below applies.
#
# ## MNSP directional offers
#
# Directional offers specify prices, band capacities and available transfer capacity.
# For receiving-end flow ``q^d`` in direction ``d``, an offer-band representation is
#
# ```math
# q^d=\sum_bq_b^d,\qquad0\le q_b^d\le Q_b^d,\qquad q^d\le A^d.
# ```
#
# Offer cost over an interval of ``h`` hours is ``h\sum_{d,b}c_b^dq_b^d``. Receiving-end
# flow excludes DC losses: the sender supplies ``q+L`` and the receiver receives ``q``.
# Terminal loss factors refer these transfers to the regional reference nodes:
#
# ```math
# I_{sender}=-\mathrm{TLF}_{from}(q+L),\qquad
# I_{receiver}=\mathrm{TLF}_{to}q.
# ```
#
# This convention is described in
# [FY2025-26 Marginal Loss Factors, §5.1, p. 63](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en).
# Losses change the energy required to supply the transfer; they are not a separate offer.
# The MNSP convention applies to the configuration for the period being studied.
#
# ## Input map and annual applicability
#
# | Input | MMSDM tables and fields |
# | --- | --- |
# | Region pair | `INTERCONNECTOR.REGIONFROM`, `REGIONTO` |
# | Equation and loss share | `INTERCONNECTORCONSTRAINT.LOSSCONSTANT`, `LOSSFLOWCOEFFICIENT`, `FROMREGIONLOSSSHARE` |
# | Demand coefficients | `LOSSFACTORMODEL.REGIONID`, `DEMANDCOEFFICIENT` |
# | Breakpoints | `LOSSMODEL.LOSSSEGMENT`, `MWBREAKPOINT` |
# | Transfer limits | `DISPATCHINTERCONNECTORRES.EXPORTLIMIT`, `IMPORTLIMIT` |
# | Directional prices | `MNSP_DAYOFFER.PRICEBAND1` to `PRICEBAND10` |
# | Directional quantities | `MNSP_BIDOFFERPERIOD.BANDAVAIL1` to `BANDAVAIL10`, `MAXAVAIL` |
# | Terminal factors | `MNSP_INTERCONNECTOR.FROM_REGION_TLF`, `TO_REGION_TLF` |
#
# Field definitions are in AEMO's
# [Electricity Data Model Report](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/).
# Effective dates and versions determine applicable inputs. Archive months identify storage
# partitions, not the applicability of loss equations. See
# [Loss inputs and assumptions](../interconnector-losses.md) for annual equations and configuration changes.
#
# !!! note "Replication coverage"
#     The replica's breakpoint span is a hard flow boundary, even when a published flow
#     limit has a violation allowance. Direction-dependent MNSP loss allocation is not
#     represented; the replica uses static regional shares instead. MNSP ramp, fixed-load
#     and elastic-offer behavior remain incomplete. Basslink fixed converter losses and
#     its no-go zone are omitted;
#     regulated Basslink treatment requires separate validation. These gaps affect
#     comparisons with historical dispatch.
