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
# [CVP schedule v8.0, item 2](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf).
# The loss model also imposes a hard breakpoint span; flow-limit slack cannot extend it.
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
# ## Exact piecewise interpolation in AEMSim
#
# Let sorted breakpoints be ``B_0,\ldots,B_n``, vertex losses ``V_j``, segment widths
# ``W_j=B_j-B_{j-1}`` and chord slopes ``m_j=(V_j-V_{j-1})/W_j``. AEMSim builds
#
# ```math
# x=B_0+\sum_{j=1}^nz_j,\qquad
# L=V_0+\sum_{j=1}^nm_jz_j,\qquad0\le z_j\le W_j.
# ```
#
# For each adjacent pair it additionally requires
#
# ```math
# z_{j+1}\le W_{j+1}y_j,\qquad z_j\ge W_jy_j,\qquad y_j\in\{0,1\}.
# ```
#
# These rows force contiguous filling from the first breakpoint, even at negative prices.
# Convexity alone would not ensure a loss *equality*: with an epigraph, a negative-priced system
# could prefer inflated losses. The binaries make this package formulation a MILP. It is an
# explicit reconstruction, not a claim that AEMO implements these same binary variables.
# `NEMInterconnectorLoss` rejects concave curves and unsupported network models; its inputs are
# fixed when a standalone decision model is built.
#
# ### Pending PR #183: zero-flow anchoring
#
# On the current branch ``V_j=L^{analytic}(B_j,D)``. When a chord strictly brackets zero, its
# interpolated value at zero can differ from the analytic integral's zero value. PR #183 uses
#
# ```math
# V_j=L^{analytic}(B_j,D)-L^{chord}(0,D).
# ```
#
# This shifts every vertex equally, preserving all slopes and making the *dispatch* chord
# pass through zero. A zero breakpoint needs no shift; a range wholly on one side retains its
# analytic anchoring. This discrete anchoring is a reconstruction assumption, supported by
# sampled NEMDE XML segment factors, rather than specified by the annual report's integration rule.

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
# ## Static regional loss sharing
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
# AEMSim represents paired offers with nonnegative receiving-end flows and bounded bands:
#
# ```math
# x=q^{forward}-q^{reverse},\qquad
# q^d=\sum_bq_b^d,\qquad0\le q_b^d\le Q_b^d,\qquad q^d\le A^d.
# ```
#
# Their cost is ``h\sum_{d,b}c_b^dq_b^d``. These link prices use the directional offer
# convention and are not passed through unit energy-price referral. A direction binary prevents
# simultaneous opposing transfer:
#
# ```math
# q^{forward}\le U^{forward}y,\qquad
# q^{reverse}\le U^{reverse}(1-y),\qquad y\in\{0,1\},
# ```
#
# where ``U^d=\min(A^d,\sum_bQ_b^d)``. Zero net flow therefore means both link flows are zero.
# Terminal factors modify each active link's transfer terms to ``-\mathrm{TLF}_{from}q`` at
# the sender and ``+\mathrm{TLF}_{to}q`` at the receiver. On the current branch losses are
# additionally assigned by the configured static share.
#
# ### Pending PR #183: directional loss allocation
#
# With paired MNSP offers, #183 instead assigns loss to the active sender. Its split uses
# signed vertex bounds ``L_{min}\le0\le L_{max}``:
#
# ```math
# \ell^{forward}+\ell^{reverse}=L,\qquad
# L_{min}y\le\ell^{forward}\le L_{max}y,\qquad
# L_{min}(1-y)\le\ell^{reverse}\le L_{max}(1-y).
# ```
#
# The active sender contributes ``-\mathrm{TLF}_{from}(q+\ell)`` and the receiver
# ``+\mathrm{TLF}_{to}q``. There is no separate loss offer cost; losses change the energy
# needed to meet demand. The receiving-end convention is described in
# [FY2025-26 Marginal Loss Factors, §5.1, p. 63](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en).
# Signed bounds are necessary because resolved loss vertices need not all be positive.
#
# ## Input map and annual applicability
#
# | Input | MMSDM tables and fields | Package path |
# | --- | --- | --- |
# | Region pair | `INTERCONNECTOR.REGIONFROM`, `REGIONTO` | System interchange construction |
# | ``c_i,m_i,\sigma_i`` | `INTERCONNECTORCONSTRAINT.LOSSCONSTANT`, `LOSSFLOWCOEFFICIENT`, `FROMREGIONLOSSSHARE` | `interconnector_loss_models` |
# | Demand coefficients | `LOSSFACTORMODEL.REGIONID`, `DEMANDCOEFFICIENT` | `read_interconnector_demand_coefficients` |
# | Breakpoints | `LOSSMODEL.LOSSSEGMENT`, `MWBREAKPOINT` | `read_interconnector_loss_breakpoints` |
# | Loss-equation demand | `DISPATCHREGIONSUM.INITIALSUPPLY + DEMANDFORECAST`, plus negative BDU `DISPATCHLOAD.INITIALMW` | Build-time curve evaluation |
# | Published transfer limits | `DISPATCHINTERCONNECTORRES.EXPORTLIMIT`, `IMPORTLIMIT` | `set_interconnector_limits!` |
# | Directional bands | `MNSP_DAYOFFER.PRICEBAND1` to `PRICEBAND10`; `MNSP_BIDOFFERPERIOD.BANDAVAIL1` to `BANDAVAIL10`, `MAXAVAIL` | `set_mnsp_offers!` |
# | Direction and terminal factors | `MNSP_INTERCONNECTOR.LINKID`, `INTERCONNECTORID`, region endpoints, `FROM_REGION_TLF`, `TO_REGION_TLF` | Directional offer metadata |
#
# `set_demand!` attaches this loss-equation demand as `"loss_demand"`, separately from
# balance `TOTALDEMAND`. Directional applied offers are tracked by `DISPATCH_MNSPBIDTRK`.
# Each loss-source table resolves effective dates and versions independently; archive month
# is not the model applicability date. #183 also supplies a missing V-SA NSW demand term only
# for FY2025-26 and only when its exact source versions and remaining coefficients match the
# annual report. An explicit published coefficient, including zero, takes precedence.
# See [Loss inputs and assumptions](../interconnector-losses.md) for annual coefficients,
# provenance, defaults and the narrowly gated correction.
#
# ## Coverage and limitations
#
# The current model supports regional losses and paired MNSP bids. MNSP offer availability and
# band bounds remain hard; ramp, fixed-load and elastic-offer behavior are incomplete. Basslink
# fixed converter losses and its no-go zone are omitted. A loss breakpoint range is always a
# hard modelling limit. Rebuild the standalone decision model when demands or loss inputs change.
# The pending PR does not infer a new interconnector topology from an annual report's forecast date.
# Unmodelled network definitions and unsupported curves must be inspected before claiming fidelity.
